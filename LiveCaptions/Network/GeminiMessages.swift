import Foundation

// MARK: - 客户端 → 服务端

/// 每条客户端消息只能包含 setup / realtimeInput / clientContent 之一。
struct GeminiClientMessage: Encodable, Sendable {
    var setup: Setup?
    var realtimeInput: RealtimeInput?

    struct Setup: Encodable, Sendable {
        var model: String
        var generationConfig: GenerationConfig
        var systemInstruction: Content?
        var realtimeInputConfig: RealtimeInputConfig?
        var sessionResumption: SessionResumption?
        var inputAudioTranscription: AudioTranscriptionConfig?
        /// 原生音频模型只能输出 AUDIO；开启后服务端会把模型语音转成文字一并下发
        var outputAudioTranscription: AudioTranscriptionConfig?
        var contextWindowCompression: ContextWindowCompression?
    }

    struct GenerationConfig: Encodable, Sendable {
        var responseModalities: [String]
        var temperature: Double?
        var maxOutputTokens: Int?
    }

    struct Content: Encodable, Sendable {
        var parts: [Part]
        var role: String?

        struct Part: Encodable, Sendable {
            var text: String
        }
    }

    struct RealtimeInputConfig: Encodable, Sendable {
        var automaticActivityDetection: AutomaticActivityDetection?
        var activityHandling: String?
        var turnCoverage: String?

        struct AutomaticActivityDetection: Encodable, Sendable {
            var disabled: Bool
        }
    }

    struct SessionResumption: Encodable, Sendable {
        var handle: String?
    }

    struct AudioTranscriptionConfig: Encodable, Sendable {
        var languageCodes: [String]?
        var mode: String?
    }

    struct ContextWindowCompression: Encodable, Sendable {
        var slidingWindow: SlidingWindow
        struct SlidingWindow: Encodable, Sendable {
            var targetTokens: Int?
        }
    }

    struct RealtimeInput: Encodable, Sendable {
        var audio: Blob?
        var activityStart: EmptyObject?
        var activityEnd: EmptyObject?

        struct Blob: Encodable, Sendable {
            var mimeType: String
            var data: String // Base64
        }
    }

    /// 编码为 `{}`，用于 activityStart / activityEnd 这类无字段消息。
    struct EmptyObject: Encodable, Sendable {
        init() {}
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([String: String]())
        }
    }
}

// MARK: - 服务端 → 客户端

/// 服务端消息：顶层恰好包含 messageType 联合体中的一个字段，可能附带 usageMetadata。
struct GeminiServerMessage: Decodable, Sendable {
    var setupComplete: Empty?
    var serverContent: ServerContent?
    var sessionResumptionUpdate: SessionResumptionUpdate?
    var goAway: GoAway?
    var usageMetadata: UsageMetadata?

    struct Empty: Decodable, Sendable {}

    struct ServerContent: Decodable, Sendable {
        var modelTurn: Content?
        var turnComplete: Bool?
        var interrupted: Bool?
        var generationComplete: Bool?
        var inputTranscription: Transcription?
        var interimInputTranscription: Transcription?
        var outputTranscription: Transcription?
    }

    struct Content: Decodable, Sendable {
        var parts: [Part]?
        var role: String?

        struct Part: Decodable, Sendable {
            var text: String?
        }
    }

    struct Transcription: Decodable, Sendable {
        var text: String?
        var languageCode: String?
    }

    struct SessionResumptionUpdate: Decodable, Sendable {
        var newHandle: String?
        var resumable: Bool?
    }

    struct GoAway: Decodable, Sendable {
        /// protobuf Duration 的 JSON 形式，如 "12.5s"
        var timeLeft: String?
    }

    struct UsageMetadata: Decodable, Sendable {
        var totalTokenCount: Int?
    }
}

// MARK: - 对上层暴露的事件

enum GeminiEvent: Sendable {
    case connectionState(ConnectionState)
    /// 实时转写（中间结果，频繁更新，isFinal == false）
    case transcript(text: String, isFinal: Bool)
    /// 模型文本输出增量（captionSource == .modelOutput 时使用）
    case modelText(String)
    case turnComplete
    case error(String)
}
