import AppKit
import SwiftUI

/// 普通 Dock 应用（无主窗口）。启动后立刻显示字幕浮窗；
/// 若尚未配置 API Key 则同时打开设置窗口。
///
/// 菜单栏用原生 NSStatusItem + NSMenu（AppKit），不用 SwiftUI MenuBarExtra——
/// 后者在无主窗口的应用里点开 popover 时有概率无响应，原生菜单最稳。
/// 设置窗口用 SwiftUI WindowGroup + openWindow 打开（官方路径，不自己托管 NSWindow，
/// 之前自建 NSWindow 托管 NSHostingView/NSHostingController 在部分机器上 EXC_BAD_ACCESS）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var onLaunch: (() -> Void)?
    static var viewModel: CaptionViewModel?
    static var settings: AppSettings?
    static var onShowOverlay: (() -> Void)?
    /// 由 SwiftUI 侧（SettingsOpener）注入的开窗闭包
    static var openSettingsRequest: (() -> Void)?

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        Self.onLaunch?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标：确保浮窗可见，并打开设置界面
        Self.onShowOverlay?()
        openSettingsWindow()
        return true
    }

    // MARK: - 主菜单（Cmd+, 设置 / Cmd+Q 退出）

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "退出 Live Captions",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 设置窗口（SwiftUI WindowGroup 官方路径）

    /// 关掉设置窗口不退出应用（防御：最后一个窗口关闭也不终止）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func openSettingsWindow() {
        // 已有设置窗口就只激活，不重复打开（dock 点击时系统可能已自动开了一个）
        if !NSApp.windows.contains(where: { $0.title == "Live Captions 设置" }) {
            Self.openSettingsRequest?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 状态栏菜单（原生 AppKit）

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "captions.bubble",
            accessibilityDescription: "Live Captions"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 每次打开菜单时重建，保证“开始/停止”标题与运行状态一致
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let isRunning = Self.viewModel?.isRunning ?? false

        let toggle = NSMenuItem(
            title: isRunning ? "停止字幕" : "开始字幕",
            action: #selector(toggleCaptions), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let show = NSMenuItem(title: "显示字幕浮窗", action: #selector(showOverlay), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        if let state = Self.viewModel?.connectionState.displayText, !state.isEmpty {
            let stateItem = NSMenuItem(title: state, action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            menu.addItem(stateItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleCaptions() {
        Task { await Self.viewModel?.toggle() }
    }

    @objc private func showOverlay() {
        Self.onShowOverlay?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

/// 注入 openWindow 的透明辅助视图，挂在常驻浮窗上（浮窗启动即显示，保证闭包可用）。
private struct SettingsOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            AppDelegate.openSettingsRequest = { openWindow(id: "settings") }
        }
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
                .background(SettingsOpener())
        )
        _overlayController = State(initialValue: controller)

        AppDelegate.viewModel = viewModel
        AppDelegate.settings = settings
        AppDelegate.onShowOverlay = { controller.show() }
        AppDelegate.onLaunch = {
            controller.show()
            if settings.apiKey.isEmpty {
                // 等 SettingsOpener 注入 openWindow 后再开
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
                }
            }
        }
    }

    var body: some Scene {
        // WindowGroup + open 前检查 NSApp.windows 是否已有，避免 dock 点击时系统自动开一个、手动又开一个
        WindowGroup("Live Captions 设置", id: "settings") {
            SettingsView(settings: settings, viewModel: viewModel)
                .frame(width: 540, height: 640)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
