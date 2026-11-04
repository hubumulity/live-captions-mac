import Foundation

/// Gemini Live API（BidiGenerateContent）WebSocket 客户端。
///
/// 职责：
/// - 建连 + 发送 setup，等待 setupComplete
/// - 将本地 VAD 产出的语音片段以 activityStart / audio / activityEnd 形式转发
/// - 心跳保活：定时 Ping 帧（可选：静音音频包）
/// - 断线自动重连：指数退避 + 会话恢复（sessionResumption handle），对上层透明
/// - 响应服务端 goAway：在被踢下线前主动重连
actor GeminiLiveClient {
    struct Configuration: Sendable {
        var apiKey: String
        var model: String
        /// 非空时启用 Mimi 式 Live 流式翻译：忽略 model，改用专用翻译模型，
        /// 音频进、原文转写 + 译文转写双流出，不再按句调用 REST 翻译接口。
        /// 值为翻译目标语言的 BCP-47 代码（如 "zh-Hans"）。
        var liveTranslationTarget: String?
        var keepAliveInterval: Duration = .seconds(10)
        /// 在 Ping 之外，是否在长时间静默时额外发送 20 ms 静音包（部分网络中间件会忽略 Ping 帧）
        var sendSilenceKeepAlive = false
        var languageHints: [String] = []
        var maxReconnectDelay: Duration = .seconds(30)
    }

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case notConnected

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: "尚未配置 Gemini API Key。"
            case .invalidURL: "WebSocket 地址无效。"
            case .notConnected: "WebSocket 尚未连接。"
            }
        }
    }

    let events: AsyncStream<GeminiEvent>
    private let eventContinuation: AsyncStream<GeminiEvent>.Continuation

    private let configuration: Configuration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var shouldRun = false
    private var isSetupComplete = false
    private var reconnectAttempt = 0
    private var resumptionHandle: String?
    /// setupComplete 前到达的音频不能丢弃，否则启动后的第一句话会被截断。
    private var pendingRealtimeInputs: [GeminiClientMessage.RealtimeInput] = []
    private let maxPendingRealtimeInputs = 300

    /// 当前是否处于一次“用户活动”（已发送 activityStart 但尚未 activityEnd）
    private var activityOpen = false
    private var lastOutboundAt = ContinuousClock.now
    /// 最近一次收到转写（原文/译文任一）的时间，用于停滞检测
    private var lastTranscriptAt = ContinuousClock.now

    init(configuration: Configuration) {
        self.configuration = configuration
        (events, eventContinuation) = AsyncStream<GeminiEvent>.makeStream(bufferingPolicy: .unbounded)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        sessionConfig.timeoutIntervalForRequest = 30
        session = URLSession(configuration: sessionConfig)
    }

    // MARK: - 生命周期

    func start() async {
        guard !shouldRun else { return }
        shouldRun = true
        reconnectAttempt = 0
        await openConnection()
    }

    func stop() async {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDownSocket(closeCode: .normalClosure)
        emit(.connectionState(.idle))
        eventContinuation.finish()
    }

    // MARK: - 语音事件转发

    func send(_ event: SpeechEvent) async {
        switch event {
        case .speechStart:
            activityOpen = true
            guard !usesTranscribeModel, !isLiveTranslateMode else { return }
            await sendRealtime(.init(activityStart: .init()))
        case .audio(let data):
            await sendRealtime(.init(audio: .init(
                mimeType: "audio/pcm;rate=\(Int(AudioConstants.sampleRate))",
                data: data.base64EncodedString()
            )))
        case .speechEnd:
            activityOpen = false
            guard !usesTranscribeModel, !isLiveTranslateMode else { return }
            await sendRealtime(.init(activityEnd: .init()))
        }
    }

    // MARK: - 建连 / 重连

    private func openConnection() async {
        guard shouldRun else { return }
        guard !configuration.apiKey.isEmpty else {
            emit(.error(ClientError.missingAPIKey.localizedDescription))
            emit(.connectionState(.failed("缺少 API Key")))
            return
        }

        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        guard let url = components?.url else {
            emit(.connectionState(.failed(ClientError.invalidURL.localizedDescription)))
            return
        }

        emit(.connectionState(reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)))

        isSetupComplete = false
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        socket = task
        task.resume()

        do {
            try await sendJSON(GeminiClientMessage(setup: makeSetup()))
        } catch {
            await handleDisconnect(reason: "发送 setup 失败：\(error.localizedDescription)")
            return
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: task)
        }
        keepAliveTask = Task { [weak self] in
            await self?.keepAliveLoop(on: task)
        }
    }

    /// 专用转写模型（gemini-3.5-transcribe-live）走精简配置：
    /// 只要 responseModalities=TEXT + inputAudioTranscription，使用服务端 VAD，不发送 activityStart/End。
    private var usesTranscribeModel: Bool {
        GeminiLiveModel.isTranscribeModel(configuration.model)
    }

    /// 翻译模式：专用翻译模型自己做 turn 切分，不发送 activityStart/End（Mimi 同款）。
    private var isLiveTranslateMode: Bool {
        configuration.liveTranslationTarget != nil
    }

    private func makeSetup() -> GeminiClientMessage.Setup {
        if let target = configuration.liveTranslationTarget {
            // Mimi 式 Live 翻译（gemini-3.5-live-translate-preview）：
            // generationConfig 只带 AUDIO + translationConfig，转写开关放 setup 顶层，
            // 不设 systemInstruction / realtimeInputConfig，由模型自己切分 turn。
            return .init(
                model: "models/\(GeminiLiveModel.translate)",
                generationConfig: .init(
                    responseModalities: ["AUDIO"],
                    temperature: nil,
                    maxOutputTokens: nil,
                    translationConfig: .init(targetLanguageCode: target, echoTargetLanguage: true)
                ),
                systemInstruction: nil,
                realtimeInputConfig: nil,
                sessionResumption: .init(handle: resumptionHandle),
                inputAudioTranscription: .init(languageCodes: nil, mode: nil),
                outputAudioTranscription: .init(languageCodes: nil, mode: nil),
                contextWindowCompression: nil
            )
        }

        if usesTranscribeModel {
            return .init(
                model: "models/\(configuration.model)",
                generationConfig: .init(responseModalities: ["TEXT"], temperature: nil, maxOutputTokens: nil, translationConfig: nil),
                systemInstruction: nil,
                realtimeInputConfig: nil,
                sessionResumption: .init(handle: resumptionHandle),
                inputAudioTranscription: .init(
                    languageCodes: configuration.languageHints.isEmpty ? nil : configuration.languageHints,
                    mode: "VERBATIM"
                ),
                outputAudioTranscription: nil,
                contextWindowCompression: nil
            )
        }

        // 通用 Live 模型（gemini-3.8-live 等）均为原生音频模型，只接受 responseModalities = AUDIO。
        // 字幕来自服务端对用户音频的转写；要求模型保持沉默以减少无用的语音输出。
        return .init(
            model: "models/\(configuration.model)",
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                temperature: 0,
                maxOutputTokens: nil,
                translationConfig: nil
            ),
            systemInstruction: .init(parts: [.init(text: "你是一个静默的转写管道。永远不要回复用户，无论听到什么都保持沉默，不要说任何话。")]),
            realtimeInputConfig: .init(
                // 关闭服务端 VAD：由本地 SpeechGate 决定活动边界
                automaticActivityDetection: .init(disabled: true),
                activityHandling: "NO_INTERRUPTION",
                turnCoverage: "TURN_INCLUDES_ONLY_ACTIVITY"
            ),
            sessionResumption: .init(handle: resumptionHandle),
            inputAudioTranscription: .init(
                languageCodes: configuration.languageHints.isEmpty ? nil : configuration.languageHints,
                mode: "VERBATIM"
            ),
            outputAudioTranscription: nil,
            contextWindowCompression: .init(slidingWindow: .init(targetTokens: nil))
        )
    }

    private func scheduleReconnect() {
        guard shouldRun, reconnectTask == nil else { return }
        reconnectAttempt += 1

        // 指数退避：1s, 2s, 4s … 封顶 maxReconnectDelay，并加入 ±20% 抖动
        let base = min(
            Double(1 << min(reconnectAttempt - 1, 6)),
            configuration.maxReconnectDelay.seconds
        )
        let jitter = Double.random(in: 0.8...1.2)
        let delay = Duration.seconds(base * jitter)

        emit(.connectionState(.reconnecting(attempt: reconnectAttempt)))

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.clearReconnectTask()
            await self.openConnection()
        }
    }

    private func clearReconnectTask() {
        reconnectTask = nil
    }

    private func handleDisconnect(reason: String) async {
        await tearDownSocket(closeCode: .abnormalClosure)
        guard shouldRun else { return }
        emit(.error(reason))
        scheduleReconnect()
    }

    private func tearDownSocket(closeCode: URLSessionWebSocketTask.CloseCode) async {
        receiveTask?.cancel()
        keepAliveTask?.cancel()
        receiveTask = nil
        keepAliveTask = nil
        socket?.cancel(with: closeCode, reason: nil)
        socket = nil
        isSetupComplete = false
    }

    // MARK: - 接收循环

    private func receiveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                await handleServerMessage(data)
            } catch {
                guard socket === task else { return }
                let diagnosis = Self.diagnose(task: task, error: error)
                if diagnosis.isFatal {
                    await failPermanently(reason: diagnosis.message)
                } else {
                    await handleDisconnect(reason: "连接中断：\(diagnosis.message)")
                }
                return
            }
        }
    }

    private struct Diagnosis {
        var message: String
        var isFatal: Bool
    }

    /// 把 WebSocket 关闭码 / HTTP 握手状态码翻译成用户可读的原因，并判断是否值得重连。
    /// Gemini 在 setup 无效（模型不存在、字段错误）时返回 1007/1008 并附带说明；
    /// API Key 无效在握手阶段就返回 HTTP 4xx。这些重试也不会成功，直接报错比无限“重连中”更有用。
    private static func diagnose(task: URLSessionWebSocketTask, error: Error) -> Diagnosis {
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode), http.statusCode != 101 {
            let hint: String
            switch http.statusCode {
            case 400, 401, 403: hint = "API Key 无效或没有权限"
            case 404: hint = "接口或模型不存在"
            case 429: hint = "请求过于频繁 / 配额用尽"
            default: hint = "服务端返回 HTTP \(http.statusCode)"
            }
            return Diagnosis(message: "\(hint)（HTTP \(http.statusCode)）", isFatal: http.statusCode != 429 && http.statusCode < 500)
        }

        let code = task.closeCode
        let serverReason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch code {
        case .invalidFramePayloadData, .policyViolation, .unsupportedData, .protocolError:
            let detail = serverReason.isEmpty ? "服务端拒绝了 setup 配置" : serverReason
            if serverReason.localizedCaseInsensitiveContains("not found")
                || serverReason.localizedCaseInsensitiveContains("not supported") {
                return Diagnosis(message: "模型不可用：\(detail)。请在设置中改用 \(GeminiLiveModel.recommended)", isFatal: true)
            }
            if serverReason.localizedCaseInsensitiveContains("api key")
                || serverReason.localizedCaseInsensitiveContains("permission") {
                return Diagnosis(message: "鉴权失败：\(detail)", isFatal: true)
            }
            return Diagnosis(message: "参数被拒绝（\(code.rawValue)）：\(detail)", isFatal: true)
        case .internalServerError, .goingAway, .abnormalClosure, .normalClosure:
            let detail = serverReason.isEmpty ? error.localizedDescription : serverReason
            return Diagnosis(message: "\(detail)（关闭码 \(code.rawValue)）", isFatal: false)
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorNotConnectedToInternet || nsError.code == NSURLErrorCannotFindHost
                || nsError.code == NSURLErrorCannotConnectToHost || nsError.code == NSURLErrorTimedOut {
                return Diagnosis(message: "无法连接 generativelanguage.googleapis.com，请检查网络或代理", isFatal: false)
            }
            let detail = serverReason.isEmpty ? error.localizedDescription : serverReason
            return Diagnosis(message: detail, isFatal: false)
        }
    }

    /// 不可恢复的错误：停止重连，向上层报告 failed 状态。
    private func failPermanently(reason: String) async {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDownSocket(closeCode: .normalClosure)
        emit(.error(reason))
        emit(.connectionState(.failed(reason)))
    }

    private func handleServerMessage(_ data: Data) async {
        guard let message = try? decoder.decode(GeminiServerMessage.self, from: data) else {
            emit(.error("无法解析服务端消息，连接可能已失效"))
            return
        }

        if message.setupComplete != nil {
            isSetupComplete = true
            reconnectAttempt = 0
            emit(.connectionState(.connected))
            let pending = pendingRealtimeInputs
            pendingRealtimeInputs.removeAll(keepingCapacity: true)
            for input in pending {
                await sendRealtime(input)
            }

            // 重连前正处于讲话中：补发 activityStart，保证片段语义完整
            if pending.isEmpty, activityOpen, !usesTranscribeModel, !isLiveTranslateMode {
                Task { await sendRealtime(.init(activityStart: .init())) }
            }
            return
        }

        if let update = message.sessionResumptionUpdate {
            if update.resumable == true, let handle = update.newHandle, !handle.isEmpty {
                resumptionHandle = handle
            }
        }

        if message.goAway != nil {
            // 服务端即将关闭（通常是会话时长上限）。主动重连，使用 resumptionHandle 无缝续接。
            Task { await proactiveReconnect() }
            return
        }

        if let content = message.serverContent {
            var gotTranscript = false
            if isLiveTranslateMode {
                // 翻译模型：inputTranscription = 原文增量，outputTranscription = 译文增量
                // （Mimi 同款：两者都按增量/累积重发处理，不读 interimInputTranscription 避免重复）
                if let source = content.inputTranscription?.text, !source.isEmpty {
                    emit(.transcriptDelta(source))
                    gotTranscript = true
                }
                if let translated = content.outputTranscription?.text, !translated.isEmpty {
                    emit(.translationDelta(translated))
                    gotTranscript = true
                }
            } else {
                if let interim = content.interimInputTranscription?.text, !interim.isEmpty {
                    emit(.transcript(text: interim, isFinal: false))
                    gotTranscript = true
                }
                if let final = content.inputTranscription?.text, !final.isEmpty {
                    emit(.transcript(text: final, isFinal: true))
                    gotTranscript = true
                }
            }
            if gotTranscript { lastTranscriptAt = .now }
            // generationComplete 同样视为 turn 边界（与 turnComplete 一起定稿）
            if content.turnComplete == true || content.generationComplete == true {
                emit(.turnComplete)
            }
        }
    }

    private func proactiveReconnect() async {
        guard shouldRun else { return }
        await tearDownSocket(closeCode: .goingAway)
        reconnectAttempt = 0
        await openConnection()
    }

    // MARK: - 心跳保活

    private func keepAliveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled, socket === task {
            try? await Task.sleep(for: configuration.keepAliveInterval)
            guard !Task.isCancelled, socket === task else { return }

            // 1. WebSocket 协议层 Ping/Pong：防止 NAT / 代理 / 服务端空闲超时断开
            let pingSucceeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                task.sendPing { error in
                    continuation.resume(returning: error == nil)
                }
            }
            guard pingSucceeded else {
                await handleDisconnect(reason: "心跳超时，正在重连")
                return
            }

            // 2. 可选：应用层静音包。仅在长时间无音频发送、且不处于讲话中时发送，
            //    让服务端的输入流保持活跃（部分链路会丢弃纯 Ping 帧）。
            if configuration.sendSilenceKeepAlive,
               isSetupComplete,
               !activityOpen,
               ContinuousClock.now - lastOutboundAt >= configuration.keepAliveInterval {
                let silence = [Int16](repeating: 0, count: AudioConstants.samplesPerFrame).pcmData
                await sendRealtime(.init(audio: .init(
                    mimeType: "audio/pcm;rate=\(Int(AudioConstants.sampleRate))",
                    data: silence.base64EncodedString()
                )))
            }

            // 3. 转写停滞检测：有音频持续发出（用户在说话）但 20s 无任何转写，
            //    说明模型侧卡住（Ping 成功只证明链路通，不代表模型在干活）。
            //    主动重连比等 30s 超时更快恢复。
            if isSetupComplete,
               ContinuousClock.now - lastTranscriptAt >= .seconds(20),
               ContinuousClock.now - lastOutboundAt < .seconds(20) {
                await handleDisconnect(reason: "转写停滞超过 20 秒，正在重连")
                return
            }
        }
    }

    // MARK: - 发送

    private func sendRealtime(_ input: GeminiClientMessage.RealtimeInput) async {
        guard isSetupComplete else {
            if pendingRealtimeInputs.count >= maxPendingRealtimeInputs {
                pendingRealtimeInputs.removeFirst()
            }
            pendingRealtimeInputs.append(input)
            return
        }
        do {
            try await sendJSON(GeminiClientMessage(realtimeInput: input))
            lastOutboundAt = .now
        } catch {
            await handleDisconnect(reason: "发送失败：\(error.localizedDescription)")
        }
    }

    private func sendJSON<T: Encodable>(_ value: T) async throws {
        guard let socket else { throw ClientError.notConnected }
        let data = try encoder.encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func emit(_ event: GeminiEvent) {
        eventContinuation.yield(event)
    }
}

private extension Duration {
    var seconds: Double {
        let (secs, attos) = components
        return Double(secs) + Double(attos) / 1e18
    }
}
