import Foundation

/// 通过 Gemini REST `generateContent` 把转写文本翻译成目标语言。
/// 与 Live 转写并行：转写模型负责“听”，这里负责“译”，互不阻塞。
actor TranslationService {
    struct Configuration: Sendable {
        var apiKey: String
        var model: String
        var targetLanguage: TargetLanguage
    }

    enum TranslationError: LocalizedError {
        case http(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "翻译请求失败（HTTP \(code)）：\(body)"
            case .emptyResponse: "翻译服务未返回内容"
            }
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    /// 某些模型会拒绝 systemInstruction / generationConfig 中的字段（HTTP 400 invalid argument）。
    /// 一旦遇到就切换为“最简请求体”：把指令并入用户消息，不带任何 generationConfig。
    private var useMinimalRequest = false

    init(configuration: Configuration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.waitsForConnectivity = false
        session = URLSession(configuration: sessionConfig)
    }

    /// - Parameters:
    ///   - text: 待翻译的当前句（可能是尚未说完的半句）
    ///   - context: 之前几句原文，帮助模型保持术语与指代一致
    ///   - isPartial: 半句时提示模型不要补全、只译已出现的内容
    func translate(_ text: String, context: [String], isPartial: Bool) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await request(text: trimmed, context: context, isPartial: isPartial)
            } catch TranslationError.http(let code, _) where code == 400 && !useMinimalRequest {
                useMinimalRequest = true
                continue
            } catch TranslationError.http(let code, _) where (code == 429 || code >= 500) && attempt == 1 {
                try await Task.sleep(for: .milliseconds(400))
                continue
            }
        }
    }

    private func request(text: String, context: [String], isPartial: Bool) async throws -> String {
        var url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!
        url.append(path: "\(configuration.model):generateContent")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let target = configuration.targetLanguage
        var system = """
        你是实时字幕翻译引擎。把用户给出的「当前句」翻译成\(target.promptName)。
        要求：只输出译文本身，不要解释、不要引号、不要标注语言、不要换行。
        保留人名、品牌名等专有名词；口语化、简洁，符合字幕阅读习惯。
        如果当前句已经是\(target.promptName)，原样输出。
        """
        if isPartial {
            system += "\n当前句尚未说完：只翻译已出现的内容，不要猜测或补全后文。"
        }

        var userText = ""
        if !context.isEmpty {
            userText += "之前几句（仅供参考，不要翻译）：\n" + context.joined(separator: "\n") + "\n\n"
        }
        userText += "当前句：\n" + text

        let body: [String: Any]
        if useMinimalRequest {
            body = [
                "contents": [["role": "user", "parts": [["text": system + "\n\n" + userText]]]],
            ]
        } else {
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": userText]]]],
                "generationConfig": [
                    "temperature": 0.2,
                    "maxOutputTokens": 512,
                ],
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = Self.extractErrorMessage(from: data) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw TranslationError.http(status, message)
        }

        guard let text = Self.extractText(from: data), !text.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return text
    }

    private static func extractText(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        // 带 thinking 的模型会把思考片段标记为 thought=true，需要跳过
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}
