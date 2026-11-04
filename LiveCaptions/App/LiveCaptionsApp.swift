import AppKit
import SwiftUI

/// 普通 Dock 应用（无主窗口）。启动后立刻显示字幕浮窗；
/// 若尚未配置 API Key 则同时打开设置窗口。
///
/// 菜单栏用原生 NSStatusItem + NSMenu（AppKit），不用 SwiftUI MenuBarExtra——
/// 后者在无主窗口的应用里点开 popover 时有概率无响应，原生菜单最稳。
/// 设置窗口用 AppDelegate 自建 NSWindow 单例 + NSHostingController（不用 SwiftUI Scene 的 openWindow，
/// 那条路在 dock 点击时稳定开出两个；也不用固定 frame 修饰符，那会导致 EXC_BAD_ACCESS，
/// 改用 maxWidth/maxHeight: .infinity 填充窗口）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static var onLaunch: (() -> Void)?
    static var viewModel: CaptionViewModel?
    static var settings: AppSettings?
    static var onShowOverlay: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        Self.onLaunch?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标：确保浮窗可见，并打开设置界面（单例，不会重复）
        Self.onShowOverlay?()
        openSettingsWindow()
        return true
    }

    /// 最后一个窗口关闭也不退出应用（设置窗口只是关掉）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    // MARK: - 设置窗口（NSWindow 单例 + NSHostingController）

    @objc func openSettingsWindow() {
        // 单例：已有就直接前置，不新建——从根源上杜绝双窗口
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let settings = Self.settings, let viewModel = Self.viewModel else { return }

        // 注意：不要用 .frame(width:height:) 固定尺寸，会导致 EXC_BAD_ACCESS；
        // Form 内部是 ScrollView，必须提供最小尺寸，否则 intrinsic height 可能趋近于零。
        let hosting = NSHostingController(
            rootView: SettingsView(settings: settings, viewModel: viewModel)
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Live Captions 设置"
        window.center()
        window.delegate = self
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == settingsWindow {
            settingsWindow = nil
        }
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
        AppDelegate.settings = settings
        AppDelegate.onShowOverlay = { controller.show() }
        AppDelegate.onLaunch = {
            controller.show()
            if settings.apiKey.isEmpty {
                // 首次启动无 Key：直接调 AppDelegate 单例开窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
                }
            }
        }
    }

    var body: some Scene {
        // 占位 Scene（SwiftUI 要求至少一个）；设置窗口由 AppDelegate 手动管理，不走 Scene
        Settings {
            EmptyView()
        }
    }
}
