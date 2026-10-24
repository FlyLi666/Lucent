import AppKit
import ServiceManagement
import SwiftUI

@main @MainActor
enum LucentMain {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--cursor-refresh-test") {
            Task { @MainActor in
                await CursorRefreshTest.run()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--usage-dump") {
            Task { @MainActor in
                await UsageDebugDump.run()
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        #endif

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)        // 不占 Dock，只在菜单栏
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let monitor = Monitor()
    private let nav = DashboardNav()
    private var statusItem: NSStatusItem!
    private var bar: StatusBarRenderer!
    private var sampler: Sampler!
    private var card: CardPanel?
    private var cardMonitors: [Any] = []
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        Theme.registerFonts()
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "LucentStatusItem"
        let button = statusItem.button!
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        bar = StatusBarRenderer(button: button)

        let monitor = self.monitor
        sampler = Sampler(baseInterval: Prefs.sampleInterval) { [weak self] snap, procs in
            monitor.ingest(snap, procs)
            self?.bar.render(monitor)
        }
        sampler.start()

        #if DEBUG
        if let dir = DebugSnapshots.outputDir {
            DebugSnapshots.run(monitor: monitor, sampler: sampler, nav: nav, into: dir)
        }
        // `--open-dashboard-after N`：N 秒后走一遍「打开主窗口」，用来测窗口能不能抢到前台
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-dashboard-after"), i + 1 < args.count, let delay = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.showDashboard() }
        }
        #endif

        // 屏幕休眠时完全停止采样
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampler.pause() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampler.resume() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 在访达里再次打开 Lucent（或 `open -a Lucent`）时直接进主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    private func preferencesChanged() {
        sampler.setBaseInterval(Prefs.sampleInterval)
        bar.invalidate()
        bar.render(monitor)
    }

    // MARK: 菜单栏点击：左键卡片；右键 / Control+点击 菜单；⌥+点击 直接开主窗口

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.option) {
            showDashboard()
        } else {
            toggleCard(from: sender)
        }
    }

    // MARK: 弹出卡片

    private func toggleCard(from button: NSStatusBarButton) {
        if card != nil {
            closeCard()
            return
        }
        let view = PopoverView(
            monitor: monitor,
            openDashboard: { [weak self] in self?.showDashboard() },
            openSettings: { [weak self] in self?.showPreferences() }
        )
        let host = NSHostingView(rootView: view)
        // 卡片高度固定（进程列表预留 3 行），按内容算一次尺寸即可
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let panel = CardPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = host
        panel.setContentSize(size)

        // 放在图标正下方，水平居中，贴住屏幕边
        if let bw = button.window {
            let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = b.midX - size.width / 2
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: b.minY - 6))
        }

        card = panel
        sampler.setPopover(open: true)
        UsageStore.shared.setEnabled(UsageVisibility.enabled)
        UsageStore.shared.setVisible(true)
        // 出场：从图标方向往下落 8 点并淡入（动效关闭时直接出现）
        if UIMotion.on {
            let target = panel.frame
            panel.alphaValue = 0
            panel.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }

        // 点别处自动收起；Esc 关闭
        cardMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCard() }
        } as Any)
        cardMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            let isEsc = e.type == .keyDown && e.keyCode == 53
            let isKey = e.type == .keyDown
            let target = e.window.map(ObjectIdentifier.init)
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let card = self.card else { return false }
                if isEsc { self.closeCard(); return true }
                if isKey { return false }
                // 点在状态栏图标上交给 statusClicked 处理（切换），点在其他窗口就收起
                let cardID = ObjectIdentifier(card)
                let barID = self.statusItem.button?.window.map(ObjectIdentifier.init)
                if target != cardID && target != barID { self.closeCard() }
                return false
            }
            return swallow ? nil : e
        } as Any)
    }

    private func closeCard() {
        guard let card else { return }
        cardMonitors.forEach { NSEvent.removeMonitor($0) }
        cardMonitors.removeAll()
        self.card = nil
        // 关闭即释放整棵 SwiftUI 视图树，不在后台留任何渲染开销；有动效时先淡出 0.12 秒
        if UIMotion.on && card.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                card.animator().alphaValue = 0
            }, completionHandler: {
                card.orderOut(nil)
                card.contentView = nil
            })
        } else {
            card.orderOut(nil)
            card.contentView = nil
        }
        sampler.setPopover(open: false)
        UsageStore.shared.setVisible(window?.isVisible == true)
    }

    // MARK: 右键菜单

    private func showMenu() {
        closeCard()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(item("打开主窗口", #selector(openDashboardAction), key: "o"))
        menu.addItem(item("AI 用量…", #selector(usageAction)))

        let interval = Prefs.sampleInterval
        let rate = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        rate.attributedTitle = MenuText.withValue("刷新频率", "\(Int(interval)) 秒")
        let rateMenu = NSMenu()
        for (v, note) in [(1.0, "更跟手"), (2.0, ""), (5.0, "最省电")] {
            let i = item("", #selector(setInterval(_:)))
            i.attributedTitle = MenuText.withValue("\(Int(v)) 秒", note, small: true)
            i.representedObject = v
            i.state = v == interval ? .on : .off
            rateMenu.addItem(i)
        }
        rate.submenu = rateMenu
        menu.addItem(rate)

        let style = Prefs.style
        let styleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        styleItem.attributedTitle = MenuText.withValue("顶部栏图标", style.title)
        let styleMenu = NSMenu()
        for s in BarStyle.allCases {
            let i = item(s.title, #selector(setStyle(_:)))
            i.toolTip = s.subtitle
            i.representedObject = s.rawValue
            i.state = s == style ? .on : .off
            styleMenu.addItem(i)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(.separator())
        let login = item("登录时启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("偏好设置…", #selector(preferencesAction), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))

        // 临时挂到状态项上再模拟点击，菜单出现在系统标准位置
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func openDashboardAction() { showDashboard() }
    @objc private func preferencesAction() { showPreferences() }
    @objc private func usageAction() { nav.section = .ai; showDashboard() }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(v, forKey: Prefs.interval)
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        UserDefaults.standard.set(v, forKey: Prefs.barStyle)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: 主窗口

    private func showPreferences() {
        nav.section = .settings
        showDashboard()
    }

    private func showDashboard() {
        closeCard()
        NSApp.setActivationPolicy(.regular)       // 窗口打开期间出现在 Dock / ⌘Tab
        if let window {
            bringToFront(window)
            return
        }

        let host = NSHostingController(rootView: DashboardView(monitor: monitor, nav: nav))
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Lucent"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 1200, height: 760))
        w.center()
        w.setFrameAutosaveName("LucentDashboard")
        window = w

        sampler.setDashboard(open: true)
        UsageStore.shared.setEnabled(UsageVisibility.enabled)
        UsageStore.shared.setVisible(true)
        bringToFront(w)
    }

    /// 从卡片 / 菜单打开窗口时，Lucent 还是后台程序：刚切成 .regular 的这一刻系统常常不理激活请求，
    /// 窗口会开在别的程序后面。先把窗口强制排到最前，等切换生效后的下一轮再激活一次。
    private func bringToFront(_ w: NSWindow) {
        w.orderFrontRegardless()
        w.makeKey()
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        sampler.setDashboard(open: false)
        UsageStore.shared.setVisible(card != nil)
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }

    // MARK: 最小主菜单（窗口打开时 ⌘O / ⌘, / ⌘W / ⌘Q 可用）

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Lucent", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("偏好设置…", #selector(preferencesAction), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Lucent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Lucent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(item("打开主窗口", #selector(openDashboardAction), key: "o"))
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

/// 无边框、不抢焦点的浮动卡片，外观完全由 SwiftUI 内容决定
final class CardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
}

/// 菜单项右侧带灰色数值，例如 "刷新频率      2 秒"
enum MenuText {
    static func withValue(_ title: String, _ value: String, small: Bool = false) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .right, location: small ? 110 : 190)]
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: p])
        if !value.isEmpty {
            s.append(NSAttributedString(string: "\t" + value, attributes: [
                .font: NSFont.menuFont(ofSize: small ? 11 : 0),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: p,
            ]))
        }
        return s
    }
}
