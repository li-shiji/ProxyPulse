import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let monitor = Monitor()
    private let tester = SpeedTester()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var dashboard: DashboardViewController!
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        }

        dashboard = DashboardViewController(monitor: monitor, tester: tester)
        popover = NSPopover()
        // 用 .applicationDefined + 全局点击监听，避免点图标时「先被关掉又立刻打开」
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = dashboard

        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.refreshStatusItem()
            self.dashboard.render()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        monitor.start()
        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    // MARK: 菜单栏

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ProxyPulse", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 ProxyPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        dashboard.render()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let color = stateColor(monitor.state)
        button.image = statusIcon(color: color)
        button.attributedTitle = NSAttributedString(
            string: " " + statusText(),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: monitor.state.isBroken ? NSColor.systemRed : NSColor.labelColor,
            ]
        )
    }

    private func statusText() -> String {
        switch monitor.state {
        case .off: return "未开启"
        case .unknown: return "检测中"
        case .tunnelBroken, .lanDown, .proxyDown:
            return "\(monitor.state.title) · \(formatDuration(monitor.stableDuration))"
        case .unstable:
            return "↓\(formatCompactSpeed(monitor.traffic.rx)) ↑\(formatCompactSpeed(monitor.traffic.tx))"
        case .ok:
            return "↓\(formatCompactSpeed(monitor.traffic.rx)) ↑\(formatCompactSpeed(monitor.traffic.tx))"
        }
    }

    /// 菜单栏圆点图标
    private func statusIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: rect).fill()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if DebugTools.handleArguments() {
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
