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
                    await self?.handle(event)
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

        finalizeActiveCaption()
        connectionState = .idle
    }

    func clear() {
        captions.removeAll()
        activeCaptionID = nil
        committedText = ""
    }

    // MARK: - 事件处理

    private func handle(_ event: GeminiEvent) {
        switch event {
        case .connectionState(let state):
            connectionState = state

        case .transcript(let text, let isFinal):
            if isFinal {
                committedText += text
                upsertActiveCaption(text: committedText, isFinal: false)
            } else {
                // interim 为当前片段的实时预览，叠加在已确认文本之后
                upsertActiveCaption(text: committedText + text, isFinal: false)
            }

        case .modelText(let text):
            committedText += text
            upsertActiveCaption(text: committedText, isFinal: false)

        case .turnComplete:
            finalizeActiveCaption()

        case .error(let message):
            lastError = message
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

    private func finalizeActiveCaption() {
        if let id = activeCaptionID, let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].isFinal = true
        }
        activeCaptionID = nil
        committedText = ""
    }

    private func trimToMaxLines() {
        let overflow = captions.count - settings.maxCaptionLines
        if overflow > 0 {
            captions.removeFirst(overflow)
        }
    }
}
