import Foundation

/// 语音门控输出事件：只有通过过滤的“有效讲话”片段才会产生事件。
enum SpeechEvent: Sendable {
    case speechStart
    case audio(Data)
    case speechEnd
}

/// 本地预处理拦截层：
/// 1. 帧级 VAD 判断语音活动；
/// 2. 片段开头先进入“预滚缓冲”（pre-roll），积累到最短时长后做片段级判定；
/// 3. 判定为语气词（嗯/啊/哦）、呻吟、喘息或过短突发音的片段被整体丢弃；
/// 4. 判定为有效讲话后，先补发缓冲音频，再实时转发后续帧，直到 VAD 判定结束。
///
/// 片段级判定依据（启发式，无需模型）：
/// - 时长：有效讲话 ≥ `minSpeechMs`；“嗯”“啊”通常 200~500 ms 且只有一个能量峰
/// - 频谱质心波动：讲话是辅音/元音交替，质心标准差大；语气词是单一稳定元音/鼻音，质心几乎不变
/// - 过零率波动：同上，讲话中清辅音会让 ZCR 产生明显跳变
/// - 频谱平坦度均值：喘息、气声、呻吟偏噪声化，平坦度高
/// - 音节数：通过能量包络峰值计数估计，≥ 2 个音节更可能是真实讲话
///
/// 非线程安全：在单一 Task 内消费音频帧流。
final class SpeechGate {
    struct Config: Sendable {
        /// 最短有效讲话时长（ms），短于此直接丢弃
        var minSpeechMs = 500
        /// 预滚最长保留时长（ms）：到达后若仍未通过判定，则丢弃整个片段
        var maxHoldMs = 1400
        /// 频谱质心标准差下限（Hz）
        var minCentroidStd: Float = 220
        /// 过零率标准差下限
        var minZcrStd: Float = 0.035
        /// 平坦度均值上限（高于此视为喘息/气声）
        var maxMeanFlatness: Float = 0.45
        /// 最少音节数（能量峰数）
        var minSyllables = 2
        /// 干净的系统音频不应因短词或音节峰值不足而被过滤。
        var acceptActiveSegment = false
        /// VAD 参数，允许系统音频使用更严格的静音判定。
        var energyMarginDb: Float = 9
        var absoluteFloorDb: Float = -55
        var hangoverFrames: Int = 15
    }

    private let config: Config
    private let extractor = FrameFeatureExtractor()
    private var vad: VoiceActivityDetector

    private enum State {
        case silence
        case holding   // 已检测到活动，正在缓冲评估
        case streaming // 已确认有效讲话，实时转发
    }

    private var state: State = .silence
    private var heldFrames: [[Int16]] = []
    private var heldFeatures: [FrameFeatures] = []

    private let frameMs = AudioConstants.frameDurationMs

    init(config: Config = Config()) {
        self.config = config
        self.vad = VoiceActivityDetector(config: .init(
            energyMarginDb: config.energyMarginDb,
            absoluteFloorDb: config.absoluteFloorDb,
            hangoverFrames: config.hangoverFrames
        ))
    }

    /// 处理一帧音频，返回需要向网络层发送的事件（可能为空）。
    func process(_ frame: [Int16]) -> [SpeechEvent] {
        let features = extractor.extract(frame)
        let isActive = vad.process(features)

        switch state {
        case .silence:
            guard isActive else { return [] }
            state = .holding
            heldFrames = [frame]
            heldFeatures = [features]
            return []

        case .holding:
            if !isActive {
                // 片段在达到最短时长前结束 → 短突发音/语气词，丢弃
                reset()
                return []
            }
            heldFrames.append(frame)
            heldFeatures.append(features)

            let heldMs = heldFrames.count * frameMs
            guard heldMs >= config.minSpeechMs else { return [] }

            if isLikelySpeech(heldFeatures) {
                state = .streaming
                var events: [SpeechEvent] = [.speechStart]
                events.append(.audio(heldFrames.flatMap { $0 }.pcmData))
                heldFrames.removeAll(keepingCapacity: true)
                heldFeatures.removeAll(keepingCapacity: true)
                return events
            }

            if heldMs >= config.maxHoldMs {
                // 长时间“嗯——”“啊——”或持续喘息：超过保留上限仍不像讲话，丢弃
                reset()
            }
            return []

        case .streaming:
            if isActive {
                return [.audio(frame.pcmData)]
            }
            reset()
            return [.speechEnd]
        }
    }

    /// 流结束时若仍在转发，补发结束事件。
    func flush() -> [SpeechEvent] {
        defer { reset() }
        return state == .streaming ? [.speechEnd] : []
    }

    private func reset() {
        state = .silence
        heldFrames.removeAll(keepingCapacity: true)
        heldFeatures.removeAll(keepingCapacity: true)
    }

    // MARK: - 片段级判定

    private func isLikelySpeech(_ features: [FrameFeatures]) -> Bool {
        guard features.count >= 2 else { return false }
        if config.acceptActiveSegment { return true }

        let meanFlatness = features.map(\.spectralFlatness).mean
        // 喘息、气声、呻吟：噪声化，平坦度高
        if meanFlatness > config.maxMeanFlatness { return false }

        let centroidStd = features.map(\.spectralCentroid).standardDeviation
        let zcrStd = features.map(\.zeroCrossingRate).standardDeviation
        let syllables = estimateSyllables(features.map(\.energyDb))

        // 稳定的单一元音/鼻音（嗯、啊、哦）：质心与 ZCR 都几乎不变，且只有 1 个能量峰
        let hasArticulation = centroidStd >= config.minCentroidStd || zcrStd >= config.minZcrStd
        let hasMultipleSyllables = syllables >= config.minSyllables

        return hasArticulation && hasMultipleSyllables
    }

    /// 用能量包络的局部峰值数粗略估计音节数。
    private func estimateSyllables(_ energy: [Float]) -> Int {
        guard energy.count >= 5 else { return energy.isEmpty ? 0 : 1 }

        // 3 帧滑动平均平滑
        var smoothed = energy
        for i in 1..<(energy.count - 1) {
            smoothed[i] = (energy[i - 1] + energy[i] + energy[i + 1]) / 3
        }

        let peakFloor = smoothed.max()! - 10 // 只统计接近峰值 10 dB 内的峰
        var peaks = 0
        var lastPeakIndex = -10
        for i in 1..<(smoothed.count - 1)
        where smoothed[i] >= peakFloor
            && smoothed[i] > smoothed[i - 1]
            && smoothed[i] >= smoothed[i + 1]
            && i - lastPeakIndex >= 5 // 两个音节至少间隔 100 ms
        {
            peaks += 1
            lastPeakIndex = i
        }
        return max(peaks, 1)
    }
}

private extension Array where Element == Float {
    var mean: Float {
        isEmpty ? 0 : reduce(0, +) / Float(count)
    }

    var standardDeviation: Float {
        guard count > 1 else { return 0 }
        let m = mean
        let variance = reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(count - 1)
        return variance.squareRoot()
    }
}
