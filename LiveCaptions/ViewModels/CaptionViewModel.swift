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
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// 当前正在更新的那一行字幕（流式中）
    private var activeCaptionID: UUID?
    /// 已确认（final）的转写片段拼接结果，用于与 interim 结果合并显示
    private var committedText = ""
    /// 专用转写模型按“句”返回 final，且不一定发 turnComplete，需要在 final 时直接结束当前行
    private var finalizesOnFinalTranscript = false
    /// 当前 turn 累积的原文 / 译文（翻译模型发的是增量或累积重发，需合并，Mimi merge_gemini 同款思路）。
    /// 注意：翻译模式由事件类型区分（transcriptDelta/translationDelta vs transcript），无需额外 flag。
    private var sourceAccumulator = ""
    private var translationAccumulator = ""

    /// turnComplete 后的尾巴静默期：等迟到的转写尾巴进来再定稿（Mimi GEMINI_TURN_TAIL_QUIET_MS 同款思路）。
    /// 静默期内有新文本到达会把 500ms 计时器重来一遍，把尾巴吸进当前行。
    private var turnSettleTask: Task<Void, Never>?
    private static let turnTailQuietPeriod: Duration = .milliseconds(500)
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

        // 翻译开启时走 Mimi 式 Live 流式翻译：单条 WebSocket 接专用翻译模型，
        // 原文与译文以双转写流下发，不再按句调用 REST 翻译接口（无每分钟配额限制）。
        let liveTranslationTarget: String? = settings.translationEnabled ? settings.targetLanguage.rawValue : nil
        let client = GeminiLiveClient(configuration: .init(
            apiKey: settings.apiKey,
            model: liveTranslationTarget != nil ? GeminiLiveModel.translate : settings.modelName,
            liveTranslationTarget: liveTranslationTarget,
            keepAliveInterval: .seconds(settings.keepAliveIntervalSeconds)
        ))
        self.client = client
        finalizesOnFinalTranscript = liveTranslationTarget == nil && GeminiLiveModel.isTranscribeModel(settings.modelName)

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

        cancelTurnSettle()
        finalizeActiveCaption()
        connectionState = .idle
    }

    func clear() {
        captions.removeAll()
        activeCaptionID = nil
        committedText = ""
        sourceAccumulator = ""
        translationAccumulator = ""
        cancelTurnSettle()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
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
            // 新文本到达：静默期计时器重来，把尾巴吸进当前行
            restartTurnSettle()
            if isFinal {
                committedText += text
                upsertActiveCaption(text: committedText, isFinal: false)
                if finalizesOnFinalTranscript {
                    finalizeActiveCaption()
                }
            } else {
                // interim 为当前片段的实时预览，叠加在已确认文本之后
                upsertActiveCaption(text: committedText + text, isFinal: false)
            }

        case .transcriptDelta(let delta):
            // 翻译模型的原文增量：合并后更新当前行
            restartTurnSettle()
            if let merged = Self.mergeChunk(sourceAccumulator, delta) {
                sourceAccumulator = merged
                upsertActiveCaption(text: merged, isFinal: false)
            }

        case .translationDelta(let delta):
            // 翻译模型的译文增量：只挂到已存在的原文行上。turn 定稿后（无原文行）
            // 才到的迟到尾巴直接丢弃，避免错挂到下一句。
            guard activeCaptionID != nil else { return }
            restartTurnSettle()
            if let merged = Self.mergeChunk(translationAccumulator, delta) {
                translationAccumulator = merged
                upsertActiveTranslation(merged)
            }

        case .turnComplete:
            scheduleTurnSettle()

        case .error(let message):
            lastError = message
        }
    }

    /// 合并模型发来的文本块（Mimi merge_gemini 的简化版）：
    /// 纯增量则追加，累积重发（以已有文本为前缀且更长）则整体替换，完全重复则忽略。
    /// 返回合并后的全文；块没有带来新内容时返回 nil。
    private static func mergeChunk(_ accumulated: String, _ chunk: String) -> String? {
        guard !chunk.isEmpty else { return nil }
        if accumulated.isEmpty { return chunk }
        if chunk.count > accumulated.count, chunk.hasPrefix(accumulated) { return chunk }
        if chunk == accumulated { return nil }
        return accumulated + chunk
    }

    /// turnComplete 后不立即定稿：等 500ms 静默期，把迟到的转写尾巴吸进当前行再定稿。
    /// 期间有新文本到达会把计时器重来一遍（见 restartTurnSettle）。
    private func scheduleTurnSettle() {
        turnSettleTask?.cancel()
        turnSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.turnTailQuietPeriod)
            guard let self, !Task.isCancelled else { return }
            self.turnSettleTask = nil
            self.finalizeActiveCaption()
        }
    }

    /// 有新文本到达且已有排队定稿时，把 500ms 计时器重来（尾巴并入当前行）；
    /// 没有排队时什么都不做。
    private func restartTurnSettle() {
        guard turnSettleTask != nil else { return }
        scheduleTurnSettle()
    }

    private func cancelTurnSettle() {
        turnSettleTask?.cancel()
        turnSettleTask = nil
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

    /// 把（合并后的）译文挂到当前流式字幕行上。
    private func upsertActiveTranslation(_ text: String) {
        guard let id = activeCaptionID,
              let index = captions.firstIndex(where: { $0.id == id })
        else { return }
        captions[index].translation = text
        captions[index].translationIsFinal = false
    }

    private func finalizeActiveCaption() {
        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].isFinal = true
            // turn 已结束：已有译文即为该句最终译文，不再有“翻译中”状态
            captions[index].translationIsFinal = true
            scheduleExpiry(for: id)
        }
        activeCaptionID = nil
        committedText = ""
        sourceAccumulator = ""
        translationAccumulator = ""
    }

    /// 整句结束后开始计时，到期自动从屏幕移除；期间若被新字幕挤出则一并清理定时任务
    private func scheduleExpiry(for id: UUID) {
        expiryTasks[id]?.cancel()
        let lifetime = settings.captionLifetimeSeconds
        expiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard let self, !Task.isCancelled else { return }
            self.expiryTasks[id] = nil
            self.captions.removeAll { $0.id == id && $0.isFinal }
        }
    }

    private func trimToMaxLines() {
        let overflow = captions.count - settings.maxCaptionLines
        guard overflow > 0 else { return }
        for removed in captions.prefix(overflow) {
            expiryTasks[removed.id]?.cancel()
            expiryTasks[removed.id] = nil
        }
        captions.removeFirst(overflow)
    }
}
