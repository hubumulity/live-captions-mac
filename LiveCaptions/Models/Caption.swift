import Foundation

/// 一条屏幕字幕。`isFinal == false` 表示该行仍在流式更新中。
struct Caption: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date
    var isFinal: Bool

    init(id: UUID = UUID(), text: String, createdAt: Date = .now, isFinal: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isFinal = isFinal
    }
}

/// 网络连接状态，供 UI 展示。
enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "连接中…"
        case .connected: "已连接"
        case .reconnecting(let attempt): "重连中（第 \(attempt) 次）"
        case .failed(let reason): "连接失败：\(reason)"
        }
    }
}
