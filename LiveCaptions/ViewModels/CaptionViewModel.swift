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

    // MARK: - Live 翻译 turn 状态（Mimi turn 提交语义的 Swift 简化版）
    //
    // 分句三路（任一触发即定稿，保证一句一行）：
    //  1. turnComplete（模型明确分句）+ 源音频流 500ms 静默 → 定稿；
    //  2. 无 turnComplete 时源音频流静默 2s → 定稿（模型没分句时的兜底）；
    //  3. 单 turn 超过 15s → 强制定稿（连续说话不停时的兜底）。
    // 注意：静默只看源音频流——译文由译文语音转写而来，滞后源音频 2~4s，不能作为分句依据。
    /// 当前 turn 累积的原文（未定稿部分）
    private var sourceAcc = ""
    /// 已定稿原文前缀：turnComplete 缺失时模型可能跨分句边界累积重发，剥离该前缀防重复
    private var sourceStrippingPrefix = ""
    /// 当前 turn 累积的译文（transAccOwner 标识属于哪个 turn）
    private var transAcc = ""
    private var transAccOwner: UUID?
    /// 上一次译文增量的到达时间：两次增量间隔大说明是两个 turn 的翻译（模型逐句生成译文语音）
    private var lastTransDeltaAt: ContinuousClock.Instant?

    private var lastSourceDeltaAt: ContinuousClock.Instant?
    private var turnStartAt: ContinuousClock.Instant?
    private var explicitTurn = false
    /// 最近定稿的行（供迟到译文更新）
    private var lastFinalized: (id: UUID, at: ContinuousClock.Instant)?
    private var settleLoopTask: Task<Void, Never>?

    /// turnComplete 后等转写尾巴的源音频静默期（Mimi GEMINI_TURN_TAIL_QUIET_MS）
    private static let turnTailQuiet: Duration = .milliseconds(500)
    /// 无 turnComplete 时源音频流静默这么久即分句
    private static let transcriptQuiet: Duration = .seconds(2)
    /// 单 turn 最长持续时间，兜底分句
    private static let maxTurnDuration: Duration = .seconds(15)
    /// 译文增量间隔超过这么久，视为上个 turn 的翻译已结束、新 turn 的翻译开始
    /// （模型逐句生成译文语音，句内增量密集、句间有停顿）
    private static let translationBurstGap: Duration = .milliseconds(1500)
    /// 定稿超过这么久的行不再接受迟到译文
    private static let lateTranslationWindow: Duration = .seconds(10)
    private static let settleTick: Duration = .milliseconds(200)

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

            let isSystemAudio = settings.audioSource == .systemAudio
            let bypassSpeechGate = isSystemAudio
                && (liveTranslationTarget != nil || GeminiLiveModel.isTranscribeModel(settings.modelName))
            audioTask = Task.detached(priority: .userInitiated) {
                if bypassSpeechGate {
                    // 转写和 Live 翻译模型都使用服务端分句，不需要本地 VAD。
                    // 系统音频是干净媒体流，直接转发可避免丢失日语单音节短词。
                    for await frame in frames {
                        await client.send(.audio(frame.pcmData))
                    }
                    return
                }

                // SpeechGate 非 Sendable，在此 Task 内独占使用
                let gateConfig: SpeechGate.Config
                if isSystemAudio {
                    // 系统音频通常是干净的媒体音轨；不要用麦克风场景的
                    // “至少两个音节”启发式误杀はい/うん/そう/ね等短词。
                    gateConfig = .init(
                        minSpeechMs: liveTranslationTarget != nil ? 100 : 150,
                        maxHoldMs: 500,
                        minCentroidStd: 0,
                        minZcrStd: 0,
                        maxMeanFlatness: 1,
                        minSyllables: 1,
                        acceptActiveSegment: true
                    )
                } else {
                    gateConfig = liveTranslationTarget != nil
                        ? .init(minSpeechMs: 250)
                        : .init()
                }
                let gate = SpeechGate(config: gateConfig)
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
            startSettleLoop()
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

        settleLoopTask?.cancel()
        settleLoopTask = nil
        finalizeActiveCaption()
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
        resetTurnState()
        connectionState = .idle
    }

    func clear() {
        captions.removeAll()
        resetTurnState()
        lastFinalized = nil
        expiryTasks.values.forEach { $0.cancel() }
        expiryTasks.removeAll()
    }

    /// 重置 turn 相关全部状态
    private func resetTurnState() {
        activeCaptionID = nil
        committedText = ""
        sourceAcc = ""
        sourceStrippingPrefix = ""
        transAcc = ""
        transAccOwner = nil
        lastTransDeltaAt = nil
        lastSourceDeltaAt = nil
        turnStartAt = nil
        explicitTurn = false
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
                }
            } else {
                // interim 为当前片段的实时预览，叠加在已确认文本之后
                upsertActiveCaption(text: committedText + text, isFinal: false)
            }

        case .transcriptDelta(let delta):
            // 翻译模型的原文增量：合并后实时显示；分句由 settleLoop 判定
            guard !delta.isEmpty else { return }
            let now = ContinuousClock.now
            if turnStartAt == nil { turnStartAt = now }
            lastSourceDeltaAt = now
            if mergeSourceChunk(delta) {
                upsertActiveCaption(text: sourceAcc, isFinal: false)
            }

        case .translationDelta(let delta):
            routeTranslationDelta(delta)

        case .turnComplete:
            // 模型明确分句：记下，settleLoop 在源音频静默 500ms 后定稿
            explicitTurn = true

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

    /// 合并原文增量。turnComplete 缺失时模型可能跨分句边界累积重发（含已定稿前缀），
    /// 先剥离该前缀再合并，避免定稿内容重复出现。
    private func mergeSourceChunk(_ chunk: String) -> Bool {
        var c = chunk
        if !sourceStrippingPrefix.isEmpty, c.hasPrefix(sourceStrippingPrefix) {
            c = String(c.dropFirst(sourceStrippingPrefix.count))
        }
        guard let merged = Self.mergeChunk(sourceAcc, c) else { return false }
        sourceAcc = merged
        return true
    }

    // MARK: - 译文路由
    //
    // 译文由译文语音转写而来，滞后源音频 2~4s，且与源音频流异步。
    // 路由只看译文流自身的连续性：增量间隔 < burstGap 说明是同一 turn 翻译的延续，
    // 否则是新 turn 的翻译开始。绝不错挂——宁可丢尾巴，不污染新 turn。

    private func routeTranslationDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        let now = ContinuousClock.now
        let burstContinues = lastTransDeltaAt.map { now - $0 < Self.translationBurstGap } ?? false
        lastTransDeltaAt = now

        if let activeID = activeCaptionID {
            if transAccOwner == activeID {
                // 当前 turn 的翻译延续：合并并实时显示
                if let merged = Self.mergeChunk(transAcc, delta) {
                    transAcc = merged
                    upsertActiveTranslation(merged)
                }
            } else if burstContinues,
                      let last = lastFinalized, now - last.at < Self.lateTranslationWindow {
                // burst 延续但累积器属于上个 turn：迟到尾巴，更新已定稿行，不污染新 turn
                updateCaptionTranslationWithDelta(last.id, delta)
            } else {
                // 新 burst：当前 turn 的翻译开始
                transAcc = ""
                transAccOwner = activeID
                if let merged = Self.mergeChunk(transAcc, delta) {
                    transAcc = merged
                    upsertActiveTranslation(merged)
                }
            }
        } else if let last = lastFinalized, now - last.at < Self.lateTranslationWindow {
            // 无进行中 turn：迟到尾巴直接更新最后定稿的行
            updateCaptionTranslationWithDelta(last.id, delta)
        }
    }

    /// 把增量合并到已定稿行的译文上（用于迟到尾巴）
    private func updateCaptionTranslationWithDelta(_ id: UUID, _ delta: String) {
        guard let index = captions.firstIndex(where: { $0.id == id }),
              let merged = Self.mergeChunk(captions[index].translation ?? "", delta)
        else { return }
        captions[index].translation = merged
    }

    // MARK: - 分句判定（settle loop，Mimi turn 提交语义）

    private func startSettleLoop() {
        settleLoopTask?.cancel()
        settleLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.settleTick)
                guard let self, !Task.isCancelled else { return }
                self.checkSettle()
            }
        }
    }

    /// 三路分句（任一触发即定稿）：
    /// 1. turnComplete + 源音频静默 500ms；2. 无 turnComplete 但源音频静默 2s；
    /// 3. 单 turn 超过 15s 兜底。静默只看源音频流（译文滞后，不能作为分句依据）。
    private func checkSettle() {
        guard isRunning, activeCaptionID != nil,
              let start = turnStartAt, let last = lastSourceDeltaAt
        else { return }
        let now = ContinuousClock.now
        let sourceQuiet = now - last
        if explicitTurn, sourceQuiet >= Self.turnTailQuiet {
            // 模型明确分句：累积器清零（模型知道边界，后续增量是全新的）
            finalizeActiveCaption()
        } else if !explicitTurn, sourceQuiet >= Self.transcriptQuiet,
                  !sourceAcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 模型没分句但说话停了：定稿；模型不知道边界，记下前缀防累积重发
            finalizeActiveCaption(forQuietCheckpoint: true)
        } else if now - start >= Self.maxTurnDuration {
            finalizeActiveCaption()
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

    /// 把（合并后的）译文挂到当前流式字幕行上。
    private func upsertActiveTranslation(_ text: String) {
        guard let id = activeCaptionID,
              let index = captions.firstIndex(where: { $0.id == id })
        else { return }
        captions[index].translation = text
        captions[index].translationIsFinal = false
    }

    /// 定稿当前行。forQuietCheckpoint=true 是静默分句（模型不知道边界），记下已定稿
    /// 原文前缀，防模型跨边界累积重发；否则累积器全部清零。
    /// 迟到译文尾巴走 lastFinalized 直接更新已定稿行，不经过累积器。
    private func finalizeActiveCaption(forQuietCheckpoint: Bool = false) {
        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].isFinal = true
            // 本 turn 的译文（若有）随定稿挂上；之后到的尾巴走 lastFinalized 更新
            if transAccOwner == id, !transAcc.isEmpty {
                captions[index].translation = transAcc
            }
            captions[index].translationIsFinal = true
            lastFinalized = (id, ContinuousClock.now)
            scheduleExpiry(for: id)
        }
        activeCaptionID = nil
        committedText = ""
        lastSourceDeltaAt = nil
        turnStartAt = nil
        explicitTurn = false
        transAcc = ""
        transAccOwner = nil
        sourceStrippingPrefix = forQuietCheckpoint ? sourceAcc : ""
        sourceAcc = ""
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
