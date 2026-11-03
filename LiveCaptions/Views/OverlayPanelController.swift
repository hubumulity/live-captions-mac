import AppKit
import SwiftUI

/// 透明、置顶、可拖拽、不抢焦点的字幕浮窗（基于 NSPanel）。
@MainActor
final class OverlayPanelController {
    private let panel: NSPanel

    init<Content: View>(rootView: Content) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting

        // 透明背景、无阴影
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // 置顶 + 全屏空间/所有桌面可见 + 不随 Mission Control 隐藏
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // 整个窗口区域都可拖拽
        panel.isMovableByWindowBackground = true
        panel.isMovable = true

        // 不成为 key window，避免打断用户当前应用的输入
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        positionAtBottomCenter()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}
