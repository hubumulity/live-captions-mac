import AVFoundation

/// 全局音频参数：Gemini Live 输入要求 16 kHz、单声道、16-bit PCM（小端）。
enum AudioConstants {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1
    /// 20 ms 一帧（320 个采样点），是 VAD 的最小决策粒度。
    static let frameDurationMs = 20
    static let samplesPerFrame = Int(sampleRate) * frameDurationMs / 1000

    static var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        )!
    }
}

/// 音频采集源的统一接口：输出 16 kHz / mono / Int16 的固定长度帧流。
protocol AudioCaptureSource: Sendable {
    func start() async throws -> AsyncStream<[Int16]>
    func stop() async
}

/// 将任意长度的 Int16 采样块重新切为固定 20 ms 帧。
/// 引用类型：只在单一音频回调线程/队列上调用 `push`，因此标记为 @unchecked Sendable。
final class FrameChunker: @unchecked Sendable {
    private var buffer: [Int16] = []
    private let frameSize: Int

    init(frameSize: Int = AudioConstants.samplesPerFrame) {
        self.frameSize = frameSize
        buffer.reserveCapacity(frameSize * 4)
    }

    func push(_ samples: [Int16]) -> [[Int16]] {
        buffer.append(contentsOf: samples)
        var frames: [[Int16]] = []
        while buffer.count >= frameSize {
            frames.append(Array(buffer[0..<frameSize]))
            buffer.removeFirst(frameSize)
        }
        return frames
    }
}

extension AVAudioPCMBuffer {
    /// 将任意输入格式的 buffer 转换为 16 kHz mono Int16 数组。
    func convertedToInt16(using converter: AVAudioConverter) -> [Int16] {
        let ratio = AudioConstants.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioConstants.targetFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return self
        }

        guard status != .error, error == nil, let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

extension Array where Element == Int16 {
    /// 小端 PCM16 字节流，直接用于 Base64 编码后发给 Gemini。
    var pcmData: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
