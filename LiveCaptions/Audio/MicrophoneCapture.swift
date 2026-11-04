import AVFoundation

/// 使用 AVAudioEngine 采集默认输入设备（麦克风）。
actor MicrophoneCapture: AudioCaptureSource {
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<[Int16]>.Continuation?

    enum CaptureError: LocalizedError {
        case permissionDenied
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "未获得麦克风权限，请在“系统设置 › 隐私与安全性 › 麦克风”中授权。"
            case .converterUnavailable: "无法创建音频格式转换器。"
            }
        }
    }

    func start() async throws -> AsyncStream<[Int16]> {
        try await requestPermission()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: AudioConstants.targetFormat) else {
            throw CaptureError.converterUnavailable
        }

        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(24))
        self.continuation = continuation
        self.engine = engine

        // Tap 回调运行在实时音频线程上，这里只做格式转换与切帧，不做任何阻塞操作。
        // converter 仅在该线程使用，标记为 nonisolated(unsafe) 以通过 Swift 6 隔离检查。
        nonisolated(unsafe) let unsafeConverter = converter
        let chunker = FrameChunker()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let samples = buffer.convertedToInt16(using: unsafeConverter)
            for frame in chunker.push(samples) {
                continuation.yield(frame)
            }
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }

    private func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw CaptureError.permissionDenied }
        default:
            throw CaptureError.permissionDenied
        }
    }
}
