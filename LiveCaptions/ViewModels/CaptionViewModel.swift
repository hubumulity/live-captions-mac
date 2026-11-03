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
    /// 上一次发起半句翻译的时间：半句翻译至少间隔这么久，避免说话不停时请求串成灾
    private var lastInterimRequestAt: ContinuousClock.Instant?
    /// 半句翻译的最小间隔（参考 Mimi PreviewRequestPacer 的请求节流思路）
    private static let interimRequestSpacing: Duration = .seconds(1.5)
    /// 整句翻译串行队列的队尾：前一句译完再发下一句，避免并发 burst 撞 429
    private var finalTranslationTail: Task<Void, Never>?
    /// 相同原文直接复用上一次译文，不再发新请求（重复内容不再刷翻译配额）
    private var lastTranslationCache: (source: String, target: String, translation: String)?
    /// turnComplete 后的尾巴静默期：等迟到的转写尾巴进来再定稿（Mimi GEMINI_TURN_TAIL_QUIET_MS 同款思路）
    private var turnSettleTask: Task<Void, Never>?
    private static let turnTailQuietPeriod: Duration = .milliseconds(500)
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

        let client = GeminiLiveClient(configuration: .init(
            apiKey: settings.apiKey,
            model: settings.modelName,
            captionSource: settings.captionSource,
            keepAliveInterval: .seconds(settings.keepAliveIntervalSeconds)
        ))
        self.client = client
        finalizesOnFinalTranscript = GeminiLiveModel.isTranscribeModel(settings.modelName)

        translator = settings.translationEnabled
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

        cancelTurnSettle()
        finalizeActiveCaption()
        interimTranslationTask?.cancel()
        interimTranslationTask = nil
        finalTranslationTail?.cancel()
        finalTranslationTail = nil
        translator = nil
        connectionState = .idle
    }

    func clear() {
        captions.removeAll()
        activeCaptionID = nil
        committedText = ""
        cancelTurnSettle()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        translationSequence.removeAll()
        recentOriginals.removeAll()
        lastInterimTranslatedText = ""
        lastInterimRequestAt = nil
        lastTranslationCache = nil
        interimTranslationTask?.cancel()
        interimTranslationTask = nil
        finalTranslationTail?.cancel()
        finalTranslationTail = nil
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
            // 新文本到达：之前排队的 turnComplete 定稿取消，尾巴并入当前行
            cancelTurnSettle()
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
            cancelTurnSettle()
            committedText += text
            upsertActiveCaption(text: committedText, isFinal: false)
            scheduleInterimTranslation()

        case .turnComplete:
            scheduleTurnSettle()

        case .error(let message):
            lastError = message
        }
    }

    /// turnComplete 后不立即定稿：等 500ms 静默期，把迟到的转写尾巴吸进当前行再定稿。
    /// 期间有新文本到达会取消这次排队（见 transcript / modelText 分支）。
    private func scheduleTurnSettle() {
        turnSettleTask?.cancel()
        turnSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.turnTailQuietPeriod)
            guard let self, !Task.isCancelled else { return }
            self.turnSettleTask = nil
            self.finalizeActiveCaption()
        }
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

    private func finalizeActiveCaption() {
        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].isFinal = true
            let original = captions[index].text
            interimTranslationTask?.cancel()
            interimTranslationTask = nil
            requestTranslation(for: id, text: original)
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

    /// 说话过程中对半句做节流翻译：同一时刻最多一个请求，新增原文足够多、且距离上次发起超过
    /// 间隔才再次发起，避免说话不停时请求串成灾。
    private func scheduleInterimTranslation() {
        guard translator != nil,
              let id = activeCaptionID,
              let caption = captions.first(where: { $0.id == id })
        else { return }

        let text = caption.text
        let grown = text.count - lastInterimTranslatedText.count
        guard interimTranslationTask == nil, grown >= 6 || (lastInterimTranslatedText.isEmpty && text.count >= 4) else { return }

        let now = ContinuousClock.now
        if let last = lastInterimRequestAt, now - last < Self.interimRequestSpacing { return }

        lastInterimTranslatedText = text
        lastInterimRequestAt = now
        interimTranslationTask = Task { [weak self] in
            await self?.performTranslation(for: id, text: text, isPartial: true)
            self?.interimTranslationTask = nil
            // 请求期间原文可能又长了不少，立刻再跟进一轮（受上面的时间节流约束）
            self?.scheduleInterimTranslation()
        }
    }

    /// 整句翻译走串行队列：前一句译完再发下一句，避免句子密集时并发 burst 撞 429。
    private func requestTranslation(for id: UUID, text: String) {
        guard translator != nil else { return }
        let previous = finalTranslationTail
        finalTranslationTail = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await self?.performTranslation(for: id, text: text, isPartial: false)
        }
    }

    private func performTranslation(for id: UUID, text: String, isPartial: Bool) async {
        guard let translator else { return }
        let sequence = (translationSequence[id] ?? 0) + 1
        translationSequence[id] = sequence
        let context = recentOriginals.filter { $0 != text }

        // 退化语句（惨叫/喘息的连续语气词串）不值得一次翻译请求：译文留空
        if Self.isFillerRun(text) {
            guard !Task.isCancelled,
                  translationSequence[id] == sequence,
                  let index = captions.firstIndex(where: { $0.id == id })
            else { return }
            captions[index].translation = ""
            captions[index].translationIsFinal = !isPartial
            return
        }

        // 相同原文（同一目标语言）直接复用上一次译文：重复内容不再刷翻译配额
        if let cache = lastTranslationCache,
           cache.source == text, cache.target == settings.targetLanguage.rawValue {
            guard !Task.isCancelled,
                  translationSequence[id] == sequence,
                  let index = captions.firstIndex(where: { $0.id == id })
            else { return }
            // 完整句译文已到达后，不再被迟到的半句译文覆盖
            if captions[index].translationIsFinal, isPartial { return }
            captions[index].translation = cache.translation
            captions[index].translationIsFinal = !isPartial
            return
        }

        do {
            let translated = try await translator.translate(text, context: context, isPartial: isPartial)
            lastTranslationCache = (text, settings.targetLanguage.rawValue, translated)
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

    /// 整句是否为退化语气词串（惨叫/喘息被识别成的连续嗯啊串）。
    /// 与 Mimi 的 degenerate_utterance 同规则：去标点/空白/拉长音后全为语气词且达到 3 个单位；
    /// 正常句子里的单个语气词、短串（<3）和笑声不受影响。
    private static func isFillerRun(_ text: String) -> Bool {
        let fillerChars: Set<Character> = [
            "嗯", "啊", "哦", "呃", "额", "唔", "吁", "呼", "呀", "哇",
            "あ", "ア", "う", "ウ", "え", "エ", "お", "オ", "ん", "ン",
            "아", "어", "음", "으",
        ]
        let fillerWords: Set<String> = [
            "ah", "uh", "um", "hmm", "oh", "ooh", "aah", "ugh", "mm", "mmm", "eh",
        ]
        let prolongation: Set<Character> = ["—", "–", "～", "〜", "ー", "ｰ"]
        // 非字母数字视为分隔符（拉长音直接丢弃），与 Mimi 的 normalize 一致
        let normalized = String(text.map { c -> Character in
            if prolongation.contains(c) { return " " }
            return (c.isLetter || c.isNumber) ? c : " "
        })
        // char mode：去空白后全为语气词字且 ≥3（如“啊啊啊”“嗯，啊，哦”）
        let chars = normalized.filter { !$0.isWhitespace }
        if chars.count >= 3 && chars.allSatisfy({ fillerChars.contains($0) }) {
            return true
        }
        // word mode：按词切分后全为语气词且 ≥3 词（如“oh oh oh”）
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        return tokens.count >= 3 && tokens.allSatisfy({ fillerWords.contains($0) })
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
