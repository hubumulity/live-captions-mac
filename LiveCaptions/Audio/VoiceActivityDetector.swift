import Accelerate
import Foundation

/// 单帧（20 ms）的声学特征。
struct FrameFeatures: Sendable {
    /// 能量（dBFS，范围约 -96 ~ 0）
    let energyDb: Float
    /// 过零率（0 ~ 1），清辅音高、元音/鼻音低
    let zeroCrossingRate: Float
    /// 频谱平坦度（0 ~ 1），噪声/气声接近 1，有谐波的人声元音接近 0
    let spectralFlatness: Float
    /// 频谱质心（Hz），反映“音色亮度”，辅音高、元音/鼻音低
    let spectralCentroid: Float
}

/// 基于 Accelerate 的轻量特征提取器（FFT 512 点，Hann 窗）。
/// 非线程安全：请在单一 Task / actor 中使用。
final class FrameFeatureExtractor {
    private let fftSize = 512
    private let halfSize = 256
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let binFrequencies: [Float]

    private var realBuffer: UnsafeMutablePointer<Float>
    private var imagBuffer: UnsafeMutablePointer<Float>
    private var windowed: [Float]
    private var magnitudes: [Float]

    init() {
        fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let binWidth = Float(AudioConstants.sampleRate) / Float(fftSize)
        binFrequencies = (0..<halfSize).map { Float($0) * binWidth }
        realBuffer = .allocate(capacity: halfSize)
        imagBuffer = .allocate(capacity: halfSize)
        windowed = [Float](repeating: 0, count: fftSize)
        magnitudes = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        realBuffer.deallocate()
        imagBuffer.deallocate()
    }

    func extract(_ frame: [Int16]) -> FrameFeatures {
        // Int16 → Float 归一化
        var floats = [Float](repeating: 0, count: frame.count)
        vDSP.convertElements(of: frame, to: &floats)
        vDSP.divide(floats, 32768, result: &floats)

        // 能量
        let rms = vDSP.rootMeanSquare(floats)
        let energyDb = 20 * log10f(max(rms, 1e-6))

        // 过零率
        var crossings = 0
        for i in 1..<floats.count where (floats[i] >= 0) != (floats[i - 1] >= 0) {
            crossings += 1
        }
        let zcr = Float(crossings) / Float(max(floats.count - 1, 1))

        // 频谱：零填充到 512，加窗
        for i in 0..<fftSize {
            windowed[i] = i < floats.count ? floats[i] * window[i] : 0
        }

        var splitComplex = DSPSplitComplex(realp: realBuffer, imagp: imagBuffer)
        windowed.withUnsafeBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPointer in
                vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(halfSize))
            }
        }
        fft.forward(input: splitComplex, output: &splitComplex)
        vDSP.squareMagnitudes(splitComplex, result: &magnitudes)

        // 忽略 DC 与最低两个 bin（< 60 Hz），减少低频隆隆噪声影响
        let start = 2
        let power = magnitudes[start...]
        let epsilon: Float = 1e-10

        var logSum: Float = 0
        var linearSum: Float = 0
        var weightedSum: Float = 0
        for (offset, value) in power.enumerated() {
            let p = value + epsilon
            logSum += logf(p)
            linearSum += p
            weightedSum += p * binFrequencies[start + offset]
        }
        let count = Float(power.count)
        let geometricMean = expf(logSum / count)
        let arithmeticMean = linearSum / count
        let flatness = min(max(geometricMean / arithmeticMean, 0), 1)
        let centroid = weightedSum / max(linearSum, epsilon)

        return FrameFeatures(
            energyDb: energyDb,
            zeroCrossingRate: zcr,
            spectralFlatness: flatness,
            spectralCentroid: centroid
        )
    }
}

/// 帧级 VAD：自适应噪声底 + 能量阈值 + 频谱平坦度，附带 hangover 防止词间停顿被切断。
struct VoiceActivityDetector: Sendable {
    struct Config: Sendable {
        /// 相对噪声底的触发阈值（dB）
        var energyMarginDb: Float = 9
        /// 绝对下限：低于此能量永远视为静音，避免安静环境里噪声底过低导致误触发
        var absoluteFloorDb: Float = -55
        /// 频谱平坦度上限：高于此值视为噪声/气声
        var maxFlatness: Float = 0.55
        /// 语音结束后的保持帧数（20 ms/帧，15 帧 = 300 ms）
        var hangoverFrames: Int = 15
        /// 噪声底上调的平滑系数（越小越慢）
        var noiseRiseRate: Float = 0.02
    }

    var config = Config()
    private var noiseFloorDb: Float = -60
    private var hangover = 0
    private var warmupFrames = 25 // 前 0.5 s 只学习噪声底

    /// 返回该帧是否属于“语音活动”（含 hangover）。
    mutating func process(_ features: FrameFeatures) -> Bool {
        if warmupFrames > 0 {
            warmupFrames -= 1
            noiseFloorDb = min(noiseFloorDb, features.energyDb)
            return false
        }

        let aboveFloor = features.energyDb > max(noiseFloorDb + config.energyMarginDb, config.absoluteFloorDb)
        let isVoiced = features.spectralFlatness < config.maxFlatness
        let isSpeechFrame = aboveFloor && isVoiced

        if isSpeechFrame {
            hangover = config.hangoverFrames
            return true
        }

        // 非语音帧：更新噪声底（快速下降、缓慢上升）
        if features.energyDb < noiseFloorDb {
            noiseFloorDb = features.energyDb
        } else {
            noiseFloorDb += (features.energyDb - noiseFloorDb) * config.noiseRiseRate
        }

        if hangover > 0 {
            hangover -= 1
            return true
        }
        return false
    }
}
