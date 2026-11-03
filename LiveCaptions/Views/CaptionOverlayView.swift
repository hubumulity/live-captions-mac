import SwiftUI

/// 字幕浮窗内容：底部对齐、新字幕从下方进入、旧字幕向上滚动并淡出。
struct CaptionOverlayView: View {
    @Bindable var viewModel: CaptionViewModel
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)

            ForEach(Array(viewModel.captions.enumerated()), id: \.element.id) { index, caption in
                CaptionLine(
                    caption: caption,
                    fontSize: settings.fontSize,
                    translationEnabled: settings.usesPipelineTranslation,
                    showOriginal: settings.showOriginalText,
                    opacity: lineOpacity(index: index, total: viewModel.captions.count)
                )
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }

            if viewModel.captions.isEmpty {
                StatusPill(state: viewModel.connectionState, isRunning: viewModel.isRunning)
            }
        }
        .frame(width: 900, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .animation(.spring(duration: 0.35, bounce: 0.1), value: viewModel.captions)
        .contextMenu {
            Button(viewModel.isRunning ? "停止字幕" : "开始字幕") {
                Task { await viewModel.toggle() }
            }
            Button("清空字幕") { viewModel.clear() }
        }
    }

    /// 越早的字幕越淡，强化“向上滚动”的层次感。
    private func lineOpacity(index: Int, total: Int) -> Double {
        guard total > 1 else { return 1 }
        let position = Double(index) / Double(total - 1)
        return 0.45 + 0.55 * position
    }
}

/// 一条字幕。开启翻译时译文为主行（大字），原文为辅行（小字、半透明）。
/// 译文尚未返回时先用原文占位，避免画面空白。
private struct CaptionLine: View {
    let caption: Caption
    let fontSize: Double
    let translationEnabled: Bool
    let showOriginal: Bool
    let opacity: Double

    private var primaryText: String {
        if translationEnabled, let translation = caption.translation, !translation.isEmpty {
            return translation
        }
        return caption.text
    }

    private var secondaryText: String? {
        guard translationEnabled, showOriginal,
              let translation = caption.translation, !translation.isEmpty
        else { return nil }
        return caption.text
    }

    /// 译文还在路上（原文已就绪但尚无译文）
    private var isAwaitingTranslation: Bool {
        translationEnabled && (caption.translation ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let secondaryText {
                Text(secondaryText)
                    .font(.system(size: fontSize * 0.55, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // 正在识别的句子可能很长：保留最新的词、从开头截断，像实时字幕一样“滚动”；
            // 已完成的句子给足 4 行空间，避免整句被省略号吞掉。
            Text(primaryText)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(isAwaitingTranslation ? .white.opacity(0.85) : .white)
                .lineLimit(caption.isFinal ? 4 : 3)
                .truncationMode(caption.isFinal ? .tail : .head)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.72))
        )
        .overlay(alignment: .topTrailing) {
            if !caption.isFinal {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .padding(8)
                    .accessibilityLabel("正在识别")
            } else if translationEnabled, !caption.translationIsFinal {
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .padding(8)
                    .accessibilityLabel("正在翻译")
            }
        }
        .opacity(opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusPill: View {
    let state: ConnectionState
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(isRunning ? state.displayText : "Live Captions 已就绪 · 点击菜单栏图标或右键此处开始")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.6)))
    }

    private var indicatorColor: Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }
}
