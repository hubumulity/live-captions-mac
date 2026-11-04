import AVFoundation
// ScreenCaptureKit 的类型尚未标注 Sendable，用 @preconcurrency 消除跨隔离域传递 SCShareableContent 的错误
@preconcurrency import ScreenCaptureKit

/// 使用 ScreenCaptureKit 采集系统播放音频（macOS 13+，需要“屏幕录制”权限）。
/// 仅开启音频输出，视频配置为最小尺寸以降低开销。
actor SystemAudioCapture: AudioCaptureSource {
    private var stream: SCStream?
    private var output: AudioStreamOutput?
    private var continuation: AsyncStream<[Int16]>.Continuation?

    enum CaptureError: LocalizedError {
        case noDisplay
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay: "未找到可用显示器。"
            case .permissionDenied: "未获得屏幕录制权限（系统音频采集依赖该权限）。"
            }
        }
    }

    func start() async throws -> AsyncStream<[Int16]> {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioConstants.sampleRate)
        config.channelCount = Int(AudioConstants.channels)
        // 最小化视频开销：2x2 像素、1 fps
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let (asyncStream, continuation) = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(24))
        self.continuation = continuation

        let output = AudioStreamOutput(continuation: continuation)
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await scStream.startCapture()

        self.stream = scStream
        self.output = output
        return asyncStream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        output = nil
        continuation?.finish()
        continuation = nil
    }
}

/// SCStreamOutput 回调在自定义串行队列上执行；这里把 CMSampleBuffer 转为 Int16 帧。
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "LiveCaptions.SystemAudioOutput")
    private let continuation: AsyncStream<[Int16]>.Continuation
    private let chunker = FrameChunker()
    private var converter: AVAudioConverter?

    init(continuation: AsyncStream<[Int16]>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let formatDescription = sampleBuffer.formatDescription,
              let pcmBuffer = sampleBuffer.toPCMBuffer(formatDescription: formatDescription)
        else { return }

        if converter == nil {
            converter = AVAudioConverter(from: pcmBuffer.format, to: AudioConstants.targetFormat)
        }
        guard let converter else { return }

        let samples = pcmBuffer.convertedToInt16(using: converter)
        for frame in chunker.push(samples) {
            continuation.yield(frame)
        }
    }
}

private extension CMSampleBuffer {
    func toPCMBuffer(formatDescription: CMFormatDescription) -> AVAudioPCMBuffer? {
        guard let asbd = formatDescription.audioStreamBasicDescription else { return nil }
        var streamDescription = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frameCount = AVAudioFrameCount(numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
