import AppKit
import SwiftUI

/// 普通 Dock 应用（无主窗口）。启动后立刻显示字幕浮窗；
/// 若尚未配置 API Key 则同时打开设置窗口。
///
/// 菜单栏用原生 NSStatusItem + NSMenu（AppKit），不用 SwiftUI MenuBarExtra——
/// 后者在无主窗口的应用里点开 popover 时有概率无响应，原生菜单最稳。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var onLaunch: (() -> Void)?
    static var viewModel: CaptionViewModel?
    static var onShowOverlay: (() -> Void)?
    static var onOpenSettings: (() -> Void)?

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        Self.onLaunch?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标：确保浮窗可见，并打开设置界面
        Self.onShowOverlay?()
        Self.onOpenSettings?()
        return true
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

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleCaptions() {
        Task { await Self.viewModel?.toggle() }
    }

    @objc private func showOverlay() {
        Self.onShowOverlay?()
    }

    @objc private func openSettings() {
        Self.onOpenSettings?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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

        AppDelegate.viewModel = viewModel
        AppDelegate.onShowOverlay = { controller.show() }
        AppDelegate.onOpenSettings = { Self.openSettingsWindow() }
        AppDelegate.onLaunch = {
            controller.show()
            if settings.apiKey.isEmpty {
                Self.openSettingsWindow()
            }
        }
    }

    /// 打开设置窗口并强制置于最前（SwiftUI Settings 窗口有时会被压在浏览器后面）。
    @MainActor
    private static func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
        // 给 SwiftUI 一点时间创建窗口，然后把设置窗口顶到最前
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKey()
                // 用完即恢复普通层级，避免一直压住别的窗口
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if window.level == .floating {
                        window.level = .normal
                    }
                }
            }
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(settings: settings, viewModel: viewModel)
        }
    }
}
