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

    /// 写进 prompt 的语言名称
    var promptName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .english: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        }
    }
}

/// 翻译用的文本模型。见 https://ai.google.dev/gemini-api/docs/models
enum GeminiTextModel {
    static let recommended = "gemini-3.5-flash-lite"

    static let presets: [(id: String, label: String)] = [
        (recommended, "Gemini 3.5 Flash-Lite（推荐，最快）"),
        ("gemini-3.8-flash", "Gemini 3.8 Flash（更准，稍慢）"),
        ("gemini-3.6-flash", "Gemini 3.6 Flash"),
    ]
}

/// 可选的 Live API 模型。见 https://ai.google.dev/gemini-api/docs/models
enum GeminiLiveModel {
    /// 专用低延迟语音转写模型，字幕场景首选
    static let recommended = "gemini-3.5-transcribe-live"

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

    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Keys.translationEnabled) }
    }

    var targetLanguage: TargetLanguage {
        didSet { defaults.set(targetLanguage.rawValue, forKey: Keys.targetLanguage) }
    }

    var translationModel: String {
        didSet { defaults.set(translationModel, forKey: Keys.translationModel) }
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
        audioSource = AudioSource(rawValue: defaults.string(forKey: Keys.audioSource) ?? "") ?? .microphone
        captionSource = CaptionSource(rawValue: defaults.string(forKey: Keys.captionSource) ?? "") ?? .inputTranscription
        let storedModel = defaults.string(forKey: Keys.modelName) ?? GeminiLiveModel.recommended
        // 旧版本把已关停的模型写进了 UserDefaults，启动时自动迁移到推荐模型
        modelName = GeminiLiveModel.shutDown.contains(storedModel) ? GeminiLiveModel.recommended : storedModel
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 28
        keepAliveIntervalSeconds = defaults.object(forKey: Keys.keepAliveInterval) as? Double ?? 10
        translationEnabled = defaults.object(forKey: Keys.translationEnabled) as? Bool ?? true
        targetLanguage = TargetLanguage(rawValue: defaults.string(forKey: Keys.targetLanguage) ?? "") ?? .simplifiedChinese
        translationModel = defaults.string(forKey: Keys.translationModel) ?? GeminiTextModel.recommended
        showOriginalText = defaults.object(forKey: Keys.showOriginalText) as? Bool ?? true
        apiKey = (try? KeychainStore.load(account: keychainAccount)) ?? ""
    }

    private enum Keys {
        static let translationEnabled = "settings.translationEnabled"
        static let targetLanguage = "settings.targetLanguage"
        static let translationModel = "settings.translationModel"
        static let showOriginalText = "settings.showOriginalText"
        static let maxCaptionLines = "settings.maxCaptionLines"
        static let audioSource = "settings.audioSource"
        static let captionSource = "settings.captionSource"
        static let modelName = "settings.modelName"
        static let fontSize = "settings.fontSize"
        static let keepAliveInterval = "settings.keepAliveInterval"
    }
}
