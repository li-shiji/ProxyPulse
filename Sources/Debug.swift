import AppKit

/// 命令行调试入口：--dump 打印实时采样，--snapshot 离屏渲染面板截图
enum DebugTools {

    static func handleArguments() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            dump(seconds: 14)
            return true
        }
        if args.contains("--speedtest") {
            speedTest()
            return true
        }
        if args.contains("--snapshot") {
            let path = args.lastIndex(of: "--snapshot").flatMap { index -> String? in
                let next = index + 1
                return next < args.count ? args[next] : nil
            } ?? "/tmp/proxypulse.png"
            snapshot(path: path, seconds: 8)
            return true
        }
        return false
    }

    // MARK: 测速按钮自检

    private static func speedTest() {
        let tester = SpeedTester()
        var done = false
        tester.start(proxy: readSystemProxy(), progress: { bytes, elapsed in
            print(String(format: "  已下载 %.1f MB / %.1f s", bytes / 1048576, elapsed))
        }, finish: { message in
            print("结果: \(message ?? "失败")")
            done = true
        })
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    // MARK: 文本采样

    private static func dump(seconds: Int) {
        let monitor = Monitor()
        monitor.onUpdate = {
            let down = formatSpeed(monitor.traffic.rx)
            let up = formatSpeed(monitor.traffic.tx)
            let latency = monitor.latencyMs.map { String(format: "%.0fms", $0) } ?? "—"
            let handshake = monitor.handshakeMs.map { String(format: "%.1fms", $0) } ?? "—"
            print(String(format: "%-14@ 状态=%-16@ 下行=%6@ %-4@ 上行=%6@ %-4@ 延迟=%8@ 握手=%8@ 丢包=%3.0f%% 代理=%@ 路由=%@",
                         "···" as NSString,
                         monitor.state.title as NSString,
                         down.value as NSString, down.unit as NSString,
                         up.value as NSString, up.unit as NSString,
                         latency as NSString,
                         handshake as NSString,
                         monitor.lossRate * 100,
                         monitor.proxy.display as NSString,
                         monitor.route.display as NSString))
        }
        monitor.start()
        RunLoop.current.run(until: Date().addingTimeInterval(Double(seconds)))
        monitor.stop()
        print("\n事件：")
        for event in monitor.events {
            print("  \(event.title) — \(event.detail)")
        }
        print("本机出口: \(monitor.proxy.display) / 路由 \(monitor.route.display) / 局域网 \(monitor.localIP ?? "—") → \(monitor.router ?? "—")")
    }

    // MARK: 离屏渲染

    private static func snapshot(path: String, seconds: Int) {
        let monitor = Monitor()
        monitor.start()
        RunLoop.current.run(until: Date().addingTimeInterval(Double(seconds)))

        let controller = DashboardViewController(monitor: monitor, tester: SpeedTester())
        _ = controller.view      // 触发 viewDidLoad，拿到自适应后的尺寸
        let size = controller.preferredContentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        controller.view.frame = container.bounds
        container.addSubview(controller.view)
        window.contentView = container
        controller.render()
        controller.view.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("截图已保存: \(path) 状态=\(monitor.state.title) 延迟=\(monitor.latencyMs ?? -1)")
        monitor.stop()
    }
}
