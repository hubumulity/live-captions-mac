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
        var captionSource: CaptionSource
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

    /// 当前是否处于一次“用户活动”（已发送 activityStart 但尚未 activityEnd）
    private var activityOpen = false
    private var lastOutboundAt = ContinuousClock.now

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
            await sendRealtime(.init(activityStart: .init()))
        case .audio(let data):
            await sendRealtime(.init(audio: .init(
                mimeType: "audio/pcm;rate=\(Int(AudioConstants.sampleRate))",
                data: data.base64EncodedString()
            )))
        case .speechEnd:
            activityOpen = false
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

    private func makeSetup() -> GeminiClientMessage.Setup {
        let systemText: String
        var maxOutputTokens: Int?
        var inputTranscription: GeminiClientMessage.AudioTranscriptionConfig?

        switch configuration.captionSource {
        case .inputTranscription:
            // 字幕来自服务端转写；模型回复被压到最短，节省 Token。
            systemText = "你是一个静默的转写管道。永远不要回复用户，无论听到什么，只输出一个空格。"
            maxOutputTokens = 1
            inputTranscription = .init(
                languageCodes: configuration.languageHints.isEmpty ? nil : configuration.languageHints,
                mode: "VERBATIM"
            )
        case .modelOutput:
            systemText = """
            你是实时字幕引擎。逐字、原样转写用户说的话，保留原语言，不翻译、不解释、不加标点以外的任何内容。
            如果没有听清，输出空字符串。
            """
        }

        return .init(
            model: "models/\(configuration.model)",
            generationConfig: .init(
                responseModalities: ["TEXT"],
                temperature: 0,
                maxOutputTokens: maxOutputTokens
            ),
            systemInstruction: .init(parts: [.init(text: systemText)]),
            realtimeInputConfig: .init(
                // 关闭服务端 VAD：由本地 SpeechGate 决定活动边界
                automaticActivityDetection: .init(disabled: true),
                activityHandling: "NO_INTERRUPTION",
                turnCoverage: "TURN_INCLUDES_ONLY_ACTIVITY"
            ),
            sessionResumption: .init(handle: resumptionHandle),
            inputAudioTranscription: inputTranscription,
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
                handleServerMessage(data)
            } catch {
                guard socket === task else { return }
                await handleDisconnect(reason: "连接中断：\(error.localizedDescription)")
                return
            }
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard let message = try? decoder.decode(GeminiServerMessage.self, from: data) else { return }

        if message.setupComplete != nil {
            isSetupComplete = true
            reconnectAttempt = 0
            emit(.connectionState(.connected))

            // 重连前正处于讲话中：补发 activityStart，保证片段语义完整
            if activityOpen {
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
            if let interim = content.interimInputTranscription?.text, !interim.isEmpty {
                emit(.transcript(text: interim, isFinal: false))
            }
            if let final = content.inputTranscription?.text, !final.isEmpty {
                emit(.transcript(text: final, isFinal: true))
            }
            if configuration.captionSource == .modelOutput,
               let parts = content.modelTurn?.parts {
                let text = parts.compactMap(\.text).joined()
                if !text.isEmpty { emit(.modelText(text)) }
            }
            if content.turnComplete == true {
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
        }
    }

    // MARK: - 发送

    private func sendRealtime(_ input: GeminiClientMessage.RealtimeInput) async {
        guard isSetupComplete else { return } // 未完成握手时丢弃，重连后由 activityOpen 补发边界
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
