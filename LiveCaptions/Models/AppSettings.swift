import Foundation
import Observation

enum AudioSource: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: "麦克风"
        case .systemAudio: "系统音频（ScreenCaptureKit）"
        }
    }
}

/// 字幕文本来源：
/// - `inputTranscription`：Gemini 对输入音频的转写（最接近“字幕”，推荐）
/// - `modelOutput`：模型文本回复（配合“逐字复述”的 system instruction 使用）
enum CaptionSource: String, CaseIterable, Identifiable, Sendable {
    case inputTranscription
    case modelOutput

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inputTranscription: "输入音频转写（推荐）"
        case .modelOutput: "模型文本输出"
        }
    }
}

/// 应用配置。普通配置落在 UserDefaults，API Key 走 Keychain。
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard
    private let keychainAccount = "gemini-api-key"

    var maxCaptionLines: Int {
        didSet { defaults.set(maxCaptionLines, forKey: Keys.maxCaptionLines) }
    }

    var audioSource: AudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Keys.audioSource) }
    }

    var captionSource: CaptionSource {
        didSet { defaults.set(captionSource.rawValue, forKey: Keys.captionSource) }
    }

    var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var keepAliveIntervalSeconds: Double {
        didSet { defaults.set(keepAliveIntervalSeconds, forKey: Keys.keepAliveInterval) }
    }

    /// 内存中的 API Key 副本；写入时同步到 Keychain。
    var apiKey: String {
        didSet {
            do {
                if apiKey.isEmpty {
                    try KeychainStore.delete(account: keychainAccount)
                } else {
                    try KeychainStore.save(apiKey, account: keychainAccount)
                }
            } catch {
                keychainError = error.localizedDescription
            }
        }
    }

    private(set) var keychainError: String?

    init() {
        maxCaptionLines = defaults.object(forKey: Keys.maxCaptionLines) as? Int ?? 3
        audioSource = AudioSource(rawValue: defaults.string(forKey: Keys.audioSource) ?? "") ?? .microphone
        captionSource = CaptionSource(rawValue: defaults.string(forKey: Keys.captionSource) ?? "") ?? .inputTranscription
        modelName = defaults.string(forKey: Keys.modelName) ?? "gemini-live-2.5-flash-preview"
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 28
        keepAliveIntervalSeconds = defaults.object(forKey: Keys.keepAliveInterval) as? Double ?? 10
        apiKey = (try? KeychainStore.load(account: keychainAccount)) ?? ""
    }

    private enum Keys {
        static let maxCaptionLines = "settings.maxCaptionLines"
        static let audioSource = "settings.audioSource"
        static let captionSource = "settings.captionSource"
        static let modelName = "settings.modelName"
        static let fontSize = "settings.fontSize"
        static let keepAliveInterval = "settings.keepAliveInterval"
    }
}
