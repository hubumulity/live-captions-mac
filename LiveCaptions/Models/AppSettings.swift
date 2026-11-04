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

/// 字幕翻译目标语言
enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

}

/// 可选的 Live API 模型。见 https://ai.google.dev/gemini-api/docs/models
enum GeminiLiveModel {
    /// 专用低延迟语音转写模型，字幕场景首选（翻译关闭时使用）
    static let recommended = "gemini-3.5-transcribe-live"
    /// Mimi 式 Live 流式翻译专用模型：音频进、原文转写 + 译文转写双流出（翻译开启时使用）
    static let translate = "gemini-3.5-live-translate-preview"

    static let presets: [(id: String, label: String)] = [
        (recommended, "Gemini 3.5 Transcribe Live（推荐，专用转写）"),
        ("gemini-3.8-live", "Gemini 3.8 Live（通用语音模型）"),
        ("gemini-3.1-flash-live-preview", "Gemini 3.1 Flash Live Preview（2026-11-17 停用）"),
        ("gemini-2.5-flash-native-audio-preview-12-2025", "Gemini 2.5 Flash Native Audio（仅限老项目）"),
    ]

    /// 已被 Google 关停的模型：连接会被服务端直接拒绝
    static let shutDown: Set<String> = [
        "gemini-live-2.5-flash-preview",
        "gemini-2.0-flash-live-001",
    ]

    /// 专用转写模型不接受 systemInstruction / 手动活动信号，仅需 inputAudioTranscription
    static func isTranscribeModel(_ model: String) -> Bool {
        model.contains("transcribe")
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

    var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var keepAliveIntervalSeconds: Double {
        didSet { defaults.set(keepAliveIntervalSeconds, forKey: Keys.keepAliveInterval) }
    }

    /// 整句字幕说完后在屏幕上停留的秒数，到期自动消失
    var captionLifetimeSeconds: Double {
        didSet { defaults.set(captionLifetimeSeconds, forKey: Keys.captionLifetime) }
    }

    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Keys.translationEnabled) }
    }

    var targetLanguage: TargetLanguage {
        didSet { defaults.set(targetLanguage.rawValue, forKey: Keys.targetLanguage) }
    }

    /// 开启翻译时是否同时显示原文（双语字幕）
    var showOriginalText: Bool {
        didSet { defaults.set(showOriginalText, forKey: Keys.showOriginalText) }
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
        audioSource = AudioSource(rawValue: defaults.string(forKey: Keys.audioSource) ?? "") ?? .systemAudio
        let storedModel = defaults.string(forKey: Keys.modelName) ?? GeminiLiveModel.recommended
        // 旧版本把已关停的模型写进了 UserDefaults，启动时自动迁移到推荐模型
        modelName = GeminiLiveModel.shutDown.contains(storedModel) ? GeminiLiveModel.recommended : storedModel
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 28
        keepAliveIntervalSeconds = defaults.object(forKey: Keys.keepAliveInterval) as? Double ?? 10
        captionLifetimeSeconds = defaults.object(forKey: Keys.captionLifetime) as? Double ?? 8
        translationEnabled = defaults.object(forKey: Keys.translationEnabled) as? Bool ?? true
        targetLanguage = TargetLanguage(rawValue: defaults.string(forKey: Keys.targetLanguage) ?? "") ?? .simplifiedChinese
        showOriginalText = defaults.object(forKey: Keys.showOriginalText) as? Bool ?? true
        apiKey = (try? KeychainStore.load(account: keychainAccount)) ?? ""
    }

    private enum Keys {
        static let captionLifetime = "settings.captionLifetime"
        static let translationEnabled = "settings.translationEnabled"
        static let targetLanguage = "settings.targetLanguage"
        static let showOriginalText = "settings.showOriginalText"
        static let maxCaptionLines = "settings.maxCaptionLines"
        static let audioSource = "settings.audioSource"
        static let modelName = "settings.modelName"
        static let fontSize = "settings.fontSize"
        static let keepAliveInterval = "settings.keepAliveInterval"
    }
}
