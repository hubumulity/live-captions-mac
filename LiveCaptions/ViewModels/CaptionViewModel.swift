import Foundation
import Observation

/// 串联音频采集 → 本地语音门控 → Gemini 客户端 → 字幕列表。
@MainActor
@Observable
final class CaptionViewModel {
    private(set) var captions: [Caption] = []
    private(set) var connectionState: ConnectionState = .idle
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let settings: AppSettings
    private var captureSource: (any AudioCaptureSource)?
    private var client: GeminiLiveClient?
    private var translator: TranslationService?
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// 当前正在更新的那一行字幕（流式中）
    private var activeCaptionID: UUID?
    /// 已确认（final）的转写片段拼接结果，用于与 interim 结果合并显示
    private var committedText = ""
    /// 专用转写模型按“句”返回 final，且不一定发 turnComplete，需要在 final 时直接结束当前行
    private var finalizesOnFinalTranscript = false

    // MARK: 翻译调度状态
    /// 每条字幕的翻译请求序号，用于丢弃过期的响应
    private var translationSequence: [UUID: Int] = [:]
    /// 正在进行的实时（半句）翻译任务
    private var interimTranslationTask: Task<Void, Never>?
    /// 上一次发起实时翻译时的原文，避免每个字符都触发请求
    private var lastInterimTranslatedText = ""
    /// 最近几句已完成的原文，作为翻译上下文
    private var recentOriginals: [String] = []
    /// 每条已完成字幕的自动消失定时任务
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    func start() async {
        guard !isRunning else { return }
        lastError = nil

        guard !settings.apiKey.isEmpty else {
            lastError = "请先在设置中配置 Gemini API Key。"
            connectionState = .failed("缺少 API Key")
            return
        }

        let directTranslation = settings.translationEnabled && settings.translationMode == .liveDirect
        var liveModel = settings.modelName
        var captionSource = settings.captionSource
        if directTranslation {
            // 直出模式必须由通用 Live 模型生成文本；专用转写模型不会翻译
            if GeminiLiveModel.isTranscribeModel(liveModel) {
                liveModel = GeminiLiveModel.generalPurpose
            }
            captionSource = .modelOutput
        }

        let client = GeminiLiveClient(configuration: .init(
            apiKey: settings.apiKey,
            model: liveModel,
            captionSource: captionSource,
            keepAliveInterval: .seconds(settings.keepAliveIntervalSeconds),
            directTranslationTarget: directTranslation ? settings.targetLanguage.promptName : nil
        ))
        self.client = client
        finalizesOnFinalTranscript = GeminiLiveModel.isTranscribeModel(liveModel)

        translator = settings.usesPipelineTranslation
            ? TranslationService(configuration: .init(
                apiKey: settings.apiKey,
                model: settings.translationModel,
                targetLanguage: settings.targetLanguage
            ))
            : nil

        let source: any AudioCaptureSource = switch settings.audioSource {
        case .microphone: MicrophoneCapture()
        case .systemAudio: SystemAudioCapture()
        }
        captureSource = source

        do {
            let frames = try await source.start()
            isRunning = true

            eventTask = Task { [weak self] in
                for await event in client.events {
                    self?.handle(event)
                }
            }

            audioTask = Task.detached(priority: .userInitiated) {
                // SpeechGate 非 Sendable，在此 Task 内独占使用
                let gate = SpeechGate()
                for await frame in frames {
                    for event in gate.process(frame) {
                        await client.send(event)
                    }
                }
                for event in gate.flush() {
                    await client.send(event)
                }
            }

            await client.start()
        } catch {
            lastError = error.localizedDescription
            connectionState = .failed(error.localizedDescription)
            await stop()
        }
    }

    func stop() async {
        isRunning = false
        audioTask?.cancel()
        eventTask?.cancel()
        audioTask = nil
        eventTask = nil

        await captureSource?.stop()
        captureSource = nil

        await client?.stop()
        client = nil

        finalizeActiveCaption()
        interimTranslationTask?.cancel()
        interimTranslationTask = nil
        translator = nil
        connectionState = .idle
    }

    func clear() {
        captions.removeAll()
        activeCaptionID = nil
        committedText = ""
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        translationSequence.removeAll()
        recentOriginals.removeAll()
        lastInterimTranslatedText = ""
        interimTranslationTask?.cancel()
        interimTranslationTask = nil
    }

    // MARK: - 事件处理

    private func handle(_ event: GeminiEvent) {
        switch event {
        case .connectionState(let state):
            connectionState = state
            // 客户端判定为不可恢复（模型不存在、API Key 无效等）：停止采集，但保留失败原因供用户查看
            if case .failed(let reason) = state, isRunning {
                Task { [weak self] in
                    await self?.stop()
                    self?.lastError = reason
                    self?.connectionState = .failed(reason)
                }
            }

        case .transcript(let text, let isFinal):
            if isFinal {
                committedText += text
                upsertActiveCaption(text: committedText, isFinal: false)
                if finalizesOnFinalTranscript {
                    finalizeActiveCaption()
                } else {
                    scheduleInterimTranslation()
                }
            } else {
                // interim 为当前片段的实时预览，叠加在已确认文本之后
                upsertActiveCaption(text: committedText + text, isFinal: false)
                scheduleInterimTranslation()
            }

        case .modelText(let text):
            committedText += text
            upsertActiveCaption(text: committedText, isFinal: false)
            scheduleInterimTranslation()

        case .turnComplete:
            finalizeActiveCaption()

        case .error(let message):
            lastError = message
        }
    }

    /// 更新或插入当前流式字幕行，并按 maxCaptionLines 裁剪旧行（旧行从顶部移除 → 视觉上向上滚动）。
    private func upsertActiveCaption(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].text = trimmed
            captions[index].isFinal = isFinal
        } else {
            let caption = Caption(text: trimmed, isFinal: isFinal)
            activeCaptionID = caption.id
            captions.append(caption)
        }
        trimToMaxLines()
    }

    private func finalizeActiveCaption() {
        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].isFinal = true
            let original = captions[index].text
            interimTranslationTask?.cancel()
            interimTranslationTask = nil
            requestTranslation(for: id, text: original, isPartial: false)
            recentOriginals.append(original)
            if recentOriginals.count > 3 { recentOriginals.removeFirst() }
            scheduleExpiry(for: id)
        }
        activeCaptionID = nil
        committedText = ""
        lastInterimTranslatedText = ""
    }

    /// 整句结束后开始计时，到期自动从屏幕移除；期间若被新字幕挤出则一并清理定时任务
    private func scheduleExpiry(for id: UUID) {
        expiryTasks[id]?.cancel()
        let lifetime = settings.captionLifetimeSeconds
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard let self, !Task.isCancelled else { return }
            self.expiryTasks[id] = nil
            self.translationSequence[id] = nil
            self.captions.removeAll { $0.id == id && $0.isFinal }
        }
    }

    // MARK: - 翻译

    /// 说话过程中对半句做节流翻译：同一时刻最多一个请求，且新增原文足够多才再次发起。
    private func scheduleInterimTranslation() {
        guard translator != nil,
              let id = activeCaptionID,
              let caption = captions.first(where: { $0.id == id })
        else { return }

        let text = caption.text
        let grown = text.count - lastInterimTranslatedText.count
        guard interimTranslationTask == nil, grown >= 6 || (lastInterimTranslatedText.isEmpty && text.count >= 4) else { return }

        lastInterimTranslatedText = text
        interimTranslationTask = Task { [weak self] in
            await self?.performTranslation(for: id, text: text, isPartial: true)
            self?.interimTranslationTask = nil
            // 请求期间原文可能又长了不少，立刻再跟进一轮
            self?.scheduleInterimTranslation()
        }
    }

    private func requestTranslation(for id: UUID, text: String, isPartial: Bool) {
        guard translator != nil else { return }
        Task { [weak self] in
            await self?.performTranslation(for: id, text: text, isPartial: isPartial)
        }
    }

    private func performTranslation(for id: UUID, text: String, isPartial: Bool) async {
        guard let translator else { return }
        let sequence = (translationSequence[id] ?? 0) + 1
        translationSequence[id] = sequence
        let context = recentOriginals.filter { $0 != text }

        do {
            let translated = try await translator.translate(text, context: context, isPartial: isPartial)
            guard !Task.isCancelled,
                  translationSequence[id] == sequence,
                  let index = captions.firstIndex(where: { $0.id == id })
            else { return }
            // 完整句译文已到达后，不再被迟到的半句译文覆盖
            if captions[index].translationIsFinal, isPartial { return }
            captions[index].translation = translated
            captions[index].translationIsFinal = !isPartial
        } catch is CancellationError {
            return
        } catch {
            if !isPartial { lastError = error.localizedDescription }
        }
    }

    private func trimToMaxLines() {
        let overflow = captions.count - settings.maxCaptionLines
        guard overflow > 0 else { return }
        for removed in captions.prefix(overflow) {
            expiryTasks[removed.id]?.cancel()
            expiryTasks[removed.id] = nil
            translationSequence[removed.id] = nil
        }
        captions.removeFirst(overflow)
    }
}
