import SwiftUI

@main
struct LiveCaptionsApp: App {
    @State private var settings = AppSettings()
    @State private var viewModel: CaptionViewModel
    @State private var overlayController: OverlayPanelController?

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _viewModel = State(initialValue: CaptionViewModel(settings: settings))
    }

    var body: some Scene {
        // 菜单栏常驻入口：开始/停止、打开设置、退出
        MenuBarExtra("Live Captions", systemImage: viewModel.isRunning ? "captions.bubble.fill" : "captions.bubble") {
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
        if overlayController == nil {
            overlayController = OverlayPanelController(
                rootView: CaptionOverlayView(viewModel: viewModel, settings: settings)
            )
        }
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
