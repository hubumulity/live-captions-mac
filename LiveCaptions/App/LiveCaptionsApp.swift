import SwiftUI

/// 普通 Dock 应用（无主窗口）。启动后立刻显示字幕浮窗；
/// 若尚未配置 API Key 则同时打开设置窗口。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Self.onLaunch?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 再次双击 .app 时重新显示浮窗
        Self.onLaunch?()
        return true
    }
}

@main
struct LiveCaptionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var viewModel: CaptionViewModel
    @State private var overlayController: OverlayPanelController?

    init() {
        let settings = AppSettings()
        let viewModel = CaptionViewModel(settings: settings)
        _settings = State(initialValue: settings)
        _viewModel = State(initialValue: viewModel)

        let controller = OverlayPanelController(
            rootView: CaptionOverlayView(viewModel: viewModel, settings: settings)
        )
        _overlayController = State(initialValue: controller)

        AppDelegate.onLaunch = {
            controller.show()
            if settings.apiKey.isEmpty {
                Self.openSettingsWindow()
            }
        }
    }

    /// macOS 14+ 的 Settings 场景可通过该 selector 以编程方式打开
    @MainActor
    private static func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // 菜单栏入口：开始/停止、打开设置、退出（图标固定为静态，避免动态切换导致点击无响应）
        MenuBarExtra("Live Captions", systemImage: "captions.bubble") {
            MenuContentView(viewModel: viewModel, settings: settings) {
                showOverlay()
            }
        }

        Settings {
            SettingsView(settings: settings, viewModel: viewModel)
        }
    }

    @MainActor
    private func showOverlay() {
        overlayController?.show()
    }
}

private struct MenuContentView: View {
    @Bindable var viewModel: CaptionViewModel
    @Bindable var settings: AppSettings
    let onShowOverlay: () -> Void

    var body: some View {
        Button(viewModel.isRunning ? "停止字幕" : "开始字幕") {
            Task { await viewModel.toggle() }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button("显示字幕浮窗") { onShowOverlay() }

        Divider()

        Text(viewModel.connectionState.displayText)
            .foregroundStyle(.secondary)

        Divider()

        SettingsLink { Text("设置…") }
            .keyboardShortcut(",", modifiers: .command)

        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
