import AppKit

func stateColor(_ state: LinkState) -> NSColor {
    switch state {
    case .ok: return NSColor.systemGreen
    case .unstable: return NSColor.systemYellow
    case .tunnelBroken, .lanDown, .proxyDown: return NSColor.systemRed
    case .off, .unknown: return NSColor.secondaryLabelColor
    }
}

// MARK: - 状态圆点

final class DotView: NSView {
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 11, height: 11) }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
    }
}

// MARK: - 卡片

final class CardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer?.borderWidth = 0.5
        }
    }
}

// MARK: - 速度曲线

final class SpeedChartView: NSView {
    var rxSamples: [Double] = []
    var txSamples: [Double] = []
    var latencySamples: [Double?] = []
    /// 时间轴总格数，与 Monitor 的历史长度一致
    var capacity: Int = 90

    private let downColor = NSColor.systemBlue
    private let upColor = NSColor.systemGreen
    private let stripHeight: CGFloat = 20

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let plotRect = NSRect(x: 0, y: stripHeight + 5,
                              width: bounds.width, height: bounds.height - stripHeight - 5)
        let stripRect = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)

        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for index in 0...2 {
            let y = plotRect.minY + plotRect.height * CGFloat(index) / 2
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.stroke()

        let peak = max((rxSamples + txSamples).max() ?? 0, 48 * 1024)
        // 刚启动时格子少一些，曲线不至于挤在最后一小段；数据多了再逐步扩到满格
        let slots = min(capacity, max(24, max(rxSamples.count, latencySamples.count) + 6))
        let slot = bounds.width / CGFloat(max(slots - 1, 1))

        func scaleY(_ value: Double) -> CGFloat {
            plotRect.minY + plotRect.height * CGFloat(min(max(value / peak, 0), 1))
        }

        /// 最新数据贴右边，历史向左生长
        func xPos(_ index: Int, _ count: Int) -> CGFloat {
            bounds.width - CGFloat(count - 1 - index) * slot
        }

        if rxSamples.count > 1 {
            let area = areaPath(rxSamples, xPos: xPos, base: plotRect.minY, scaleY: scaleY)
            NSGradient(starting: downColor.withAlphaComponent(0.26),
                       ending: downColor.withAlphaComponent(0.01))?
                .draw(in: area, angle: -90)

            downColor.withAlphaComponent(0.9).setStroke()
            let line = linePath(rxSamples, xPos: xPos, scaleY: scaleY)
            line.lineWidth = 1.5
            line.stroke()
        }

        if txSamples.count > 1 {
            upColor.withAlphaComponent(0.85).setStroke()
            let line = linePath(txSamples, xPos: xPos, scaleY: scaleY)
            line.lineWidth = 1.3
            line.stroke()
        }

        // 延迟带：每次探测一根竖条，量程固定 0–3000ms，失败处标红点
        let range: Double = 3000
        let count = latencySamples.count
        let barWidth = max(slot - 1.4, 1.2)

        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: stripRect.minY, width: bounds.width, height: 0.6).fill()

        for (index, value) in latencySamples.enumerated() {
            let x = bounds.width - CGFloat(count - 1 - index) * slot - barWidth / 2
            guard let value else {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + barWidth / 2 - 1.8,
                                            y: stripRect.minY + 0.5,
                                            width: 3.6, height: 3.6)).fill()
                continue
            }
            let ratio = min(max(value / range, 0.02), 1)
            let height = (stripRect.height - 2) * CGFloat(ratio)
            let color: NSColor
            switch value {
            case ..<400: color = NSColor.systemGreen
            case ..<1200: color = NSColor.systemYellow
            case ..<2500: color = NSColor.systemOrange
            default: color = NSColor.systemRed
            }
            color.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: stripRect.minY + 1,
                                             width: barWidth, height: height),
                         xRadius: 0.6, yRadius: 0.6).fill()
        }
    }

    private func areaPath(_ values: [Double], xPos: (Int, Int) -> CGFloat, base: CGFloat,
                          scaleY: (Double) -> CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let count = values.count
        path.move(to: NSPoint(x: xPos(0, count), y: base))
        for (index, value) in values.enumerated() {
            path.line(to: NSPoint(x: xPos(index, count), y: scaleY(value)))
        }
        path.line(to: NSPoint(x: xPos(count - 1, count), y: base))
        path.close()
        return path
    }

    private func linePath(_ values: [Double], xPos: (Int, Int) -> CGFloat,
                          scaleY: (Double) -> CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        let count = values.count
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: xPos(index, count), y: scaleY(value))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        return path
    }
}

// MARK: - 主面板

final class DashboardViewController: NSViewController {

    private let monitor: Monitor
    private let tester: SpeedTester

    private let panelWidth: CGFloat = 376

    private let dot = DotView()
    private let stateLabel = NSTextField(labelWithString: "正在检测")
    private let stateDetail = NSTextField(labelWithString: "正在建立基线…")
    private let latencyBadge = NSTextField(labelWithString: "—")

    private let downValue = NSTextField(labelWithString: "0")
    private let downUnit = NSTextField(labelWithString: "B/s")
    private let upValue = NSTextField(labelWithString: "0")
    private let upUnit = NSTextField(labelWithString: "B/s")
    private let chart = SpeedChartView()

    private let latencyValue = NSTextField(labelWithString: "—")
    private let domesticValue = NSTextField(labelWithString: "—")
    private let lossValue = NSTextField(labelWithString: "0%")
    private let jitterValue = NSTextField(labelWithString: "—")
    private let outageValue = NSTextField(labelWithString: "0")
    private let downtimeValue = NSTextField(labelWithString: "0 秒")

    private let proxyValue = NSTextField(labelWithString: "—")
    private let routeValue = NSTextField(labelWithString: "—")
    private let lanValue = NSTextField(labelWithString: "—")
    private let totalValue = NSTextField(labelWithString: "")

    private let testButton = NSButton(title: "测速", target: nil, action: nil)
    private let resetButton = NSButton(title: "重置统计", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出", target: nil, action: nil)
    private let testResult = NSTextField(labelWithString: "点「测速」跑一次真实下载，看当前链路能跑多快")

    private let eventStack = NSStackView()
    private var eventSignature = ""
    private var contentStack: NSStackView!

    init(monitor: Monitor, tester: SpeedTester) {
        self.monitor = monitor
        self.tester = tester
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 520))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        buildLayout(in: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        resizeToFitContent()
    }

    /// 面板高度跟随内容，避免下方留白
    private func resizeToFitContent() {
        view.layoutSubtreeIfNeeded()
        let height = ceil(contentStack.fittingSize.height + 26)
        guard abs(preferredContentSize.height - height) > 0.5 else { return }
        preferredContentSize = NSSize(width: panelWidth, height: height)
        view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
    }

    // MARK: 布局

    private func buildLayout(in root: NSView) {
        styleLabels()

        let header = buildHeader()
        let speedCard = buildSpeedCard()
        let metrics = buildMetrics()
        let details = buildDetails()
        let buttons = buildButtons()
        let events = buildEvents()

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        for child in [header, speedCard, metrics, details, buttons, testResult, events, totalValue] {
            contentStack.addArrangedSubview(child)
        }
        contentStack.setCustomSpacing(8, after: buttons)
        contentStack.setCustomSpacing(13, after: speedCard)
        contentStack.setCustomSpacing(13, after: details)
        contentStack.setCustomSpacing(11, after: testResult)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
        ])

        // 每块都铺满面板宽度
        for child in contentStack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        speedCard.heightAnchor.constraint(equalToConstant: 146).isActive = true
    }

    private func buildHeader() -> NSView {
        let textStack = NSStackView(views: [stateLabel, stateDetail])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [dot, textStack, NSView(), latencyBadge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        dot.widthAnchor.constraint(equalToConstant: 11).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 11).isActive = true
        latencyBadge.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func buildSpeedCard() -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let down = speedBlock(arrow: "↓", title: "下行", value: downValue, unit: downUnit)
        let up = speedBlock(arrow: "↑", title: "上行", value: upValue, unit: upUnit)
        let row = NSStackView(views: [down, up])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 8

        chart.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [row, chart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chart.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return card
    }

    private func speedBlock(arrow: String, title: String,
                            value: NSTextField, unit: NSTextField) -> NSView {
        let arrowLabel = NSTextField(labelWithString: arrow)
        arrowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        arrowLabel.textColor = .tertiaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10)
        titleLabel.textColor = .secondaryLabelColor

        let captionRow = NSStackView(views: [arrowLabel, titleLabel])
        captionRow.orientation = .horizontal
        captionRow.spacing = 3
        captionRow.alignment = .centerY

        let numberRow = NSStackView(views: [value, unit])
        numberRow.orientation = .horizontal
        numberRow.alignment = .lastBaseline
        numberRow.spacing = 3
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        unit.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [captionRow, numberRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    private func buildMetrics() -> NSView {
        let blocks = [statBlock("国内", domesticValue),
                      statBlock("丢包", lossValue),
                      statBlock("抖动", jitterValue),
                      statBlock("断线", outageValue),
                      statBlock("累计中断", downtimeValue)]
        let row = NSStackView(views: blocks)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 6
        return row
    }

    private func statBlock(_ title: String, _ value: NSTextField) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 9.5)
        titleLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private func buildDetails() -> NSView {
        let stack = NSStackView(views: [detailRow("代理", proxyValue),
                                        detailRow("路由", routeValue),
                                        detailRow("局域网", lanValue)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func detailRow(_ key: String, _ value: NSTextField) -> NSView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 10.5)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let row = NSStackView(views: [keyLabel, value, NSView()])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func buildButtons() -> NSView {
        for button in [testButton, resetButton, quitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
        }
        testButton.target = self
        testButton.action = #selector(runSpeedTest)
        resetButton.target = self
        resetButton.action = #selector(resetStats)
        quitButton.target = self
        quitButton.action = #selector(quitApp)

        let row = NSStackView(views: [testButton, resetButton, NSView(), quitButton])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func buildEvents() -> NSView {
        let title = NSTextField(labelWithString: "事件记录")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .secondaryLabelColor

        eventStack.orientation = .vertical
        eventStack.alignment = .leading
        eventStack.spacing = 3

        let stack = NSStackView(views: [title, eventStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        eventStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func styleLabels() {
        stateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stateDetail.font = .systemFont(ofSize: 10.5)
        stateDetail.textColor = .secondaryLabelColor
        stateDetail.lineBreakMode = .byTruncatingTail
        latencyBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        latencyBadge.textColor = .secondaryLabelColor

        for (value, unit, color) in [(downValue, downUnit, NSColor.systemBlue),
                                     (upValue, upUnit, NSColor.systemGreen)] {
            value.font = .monospacedDigitSystemFont(ofSize: 25, weight: .semibold)
            value.textColor = color
            unit.font = .systemFont(ofSize: 10.5, weight: .medium)
            unit.textColor = .secondaryLabelColor
        }
        for value in [latencyValue, domesticValue, lossValue, jitterValue, outageValue, downtimeValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingTail
        }
        for value in [proxyValue, routeValue, lanValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.lineBreakMode = .byTruncatingTail
        }
        testResult.font = .systemFont(ofSize: 10.5)
        testResult.textColor = .secondaryLabelColor
        testResult.lineBreakMode = .byTruncatingTail
        totalValue.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        totalValue.textColor = .tertiaryLabelColor
    }

    // MARK: 渲染

    func render() {
        dot.color = stateColor(monitor.state)
        stateLabel.stringValue = monitor.state.title
        stateLabel.textColor = monitor.state.isBroken ? .systemRed : .labelColor

        if monitor.state.isBroken {
            stateDetail.stringValue = monitor.stableDuration > 1
                ? "已中断 \(formatDuration(monitor.stableDuration)) · \(monitor.probeMessage)"
                : monitor.probeMessage
        } else if monitor.state == .off {
            stateDetail.stringValue = "未检测到代理，打开 Shadowrocket 后自动恢复"
        } else if monitor.state == .unstable {
            stateDetail.stringValue = String(format: "最近 10 次探测丢 %.0f%%", monitor.lossRate * 100)
        } else if monitor.state == .unknown {
            stateDetail.stringValue = "正在建立基线…"
        } else {
            stateDetail.stringValue = "已稳定 \(formatDuration(monitor.stableDuration))"
        }

        latencyBadge.stringValue = monitor.latencyMs.map { String(format: "海外 %.0f ms", $0) } ?? "海外 — ms"
        if let latency = monitor.latencyMs {
            latencyBadge.textColor = latency > 3000 ? .systemRed
                : (latency > 1500 ? .systemOrange : .secondaryLabelColor)
        } else {
            latencyBadge.textColor = .tertiaryLabelColor
        }

        let down = formatSpeed(monitor.traffic.rx)
        let up = formatSpeed(monitor.traffic.tx)
        downValue.stringValue = down.value
        downUnit.stringValue = down.unit
        upValue.stringValue = up.value
        upUnit.stringValue = up.unit

        chart.rxSamples = monitor.historyTraffic.map { $0.rx }
        chart.txSamples = monitor.historyTraffic.map { $0.tx }
        chart.latencySamples = monitor.historyLatency
        chart.needsDisplay = true

        latencyValue.stringValue = monitor.latencyMs.map { String(format: "%.0f ms", $0) } ?? "—"
        latencyValue.textColor = (monitor.latencyMs ?? 0) > 1500 ? .systemOrange : .labelColor
        domesticValue.stringValue = monitor.domesticMs.map { String(format: "%.0f ms", $0) } ?? "—"
        domesticValue.textColor = monitor.domesticOK == false ? .systemOrange : .labelColor
        lossValue.stringValue = String(format: "%.0f%%", monitor.lossRate * 100)
        lossValue.textColor = monitor.lossRate > 0 ? .systemOrange : .labelColor
        jitterValue.stringValue = monitor.jitterMs > 0 ? String(format: "%.0f ms", monitor.jitterMs) : "—"
        jitterValue.textColor = monitor.jitterMs > 500 ? .systemOrange : .labelColor
        outageValue.stringValue = "\(monitor.totalOutages)"
        outageValue.textColor = monitor.totalOutages > 0 ? .systemRed : .labelColor
        downtimeValue.stringValue = monitor.totalDowntime > 0
            ? formatDuration(monitor.totalDowntime) : "0 秒"
        downtimeValue.textColor = monitor.totalDowntime > 0 ? .systemRed : .labelColor

        proxyValue.stringValue = monitor.proxy.isEnabled
            ? monitor.proxy.display
            : (monitor.route.isTunnel ? "无系统代理（TUN 模式）" : "未设置")
        routeValue.stringValue = monitor.route.interface.map { "\($0)（默认出口）" } ?? "—"
        if let ip = monitor.localIP {
            lanValue.stringValue = monitor.router.map { "\(ip) → \($0)" } ?? ip
        } else {
            lanValue.stringValue = "未连接"
        }

        totalValue.stringValue = "本次运行累计 ↓\(formatBytes(monitor.trafficTotal.rx))  ↑\(formatBytes(monitor.trafficTotal.tx))   ·   采样 1 秒 / 探测 2 秒"

        updateEvents()
    }

    private func updateEvents() {
        let signature = monitor.events.prefix(3).map { $0.id.uuidString }.joined()
        guard signature != eventSignature else { return }
        eventSignature = signature

        eventStack.arrangedSubviews.forEach {
            eventStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        if monitor.events.isEmpty {
            eventStack.addArrangedSubview(eventLine("暂无异常，连接一直很稳",
                                                    color: .secondaryLabelColor, time: ""))
        } else {
            for event in monitor.events.prefix(3) {
                let color: NSColor
                switch event.severity {
                case .bad: color = .systemRed
                case .good: color = .systemGreen
                case .warn: color = .systemOrange
                case .info: color = .secondaryLabelColor
                }
                let text = event.detail.isEmpty ? event.title : "\(event.title) · \(event.detail)"
                eventStack.addArrangedSubview(eventLine(text, color: color,
                                                        time: formatter.string(from: event.time)))
            }
        }
        for row in eventStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: eventStack.widthAnchor).isActive = true
        }
        resizeToFitContent()
    }

    private func eventLine(_ text: String, color: NSColor, time: String) -> NSView {
        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let textLabel = NSTextField(labelWithString: text)
        textLabel.font = .systemFont(ofSize: 10.5)
        textLabel.textColor = color
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [timeLabel, textLabel, NSView()])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes < 1024 { return "\(Int(bytes)) B" }
        if bytes < 1048576 { return String(format: "%.1f KB", bytes / 1024) }
        if bytes < 1073741824 { return String(format: "%.1f MB", bytes / 1048576) }
        return String(format: "%.2f GB", bytes / 1073741824)
    }

    // MARK: 操作

    @objc private func runSpeedTest() {
        guard !tester.isRunning() else { return }
        testButton.isEnabled = false
        testResult.textColor = .secondaryLabelColor
        testResult.stringValue = "正在下载测试数据…"

        tester.start(proxy: monitor.proxy) { [weak self] bytes, elapsed in
            guard let self else { return }
            let speed = elapsed > 0.2 ? bytes / elapsed : 0
            let formatted = formatSpeed(speed)
            self.testResult.stringValue = String(format: "测速中… 已下载 %.1f MB / %.1f 秒（%@ %@）",
                                                 bytes / 1048576, elapsed,
                                                 formatted.value, formatted.unit)
        } finish: { [weak self] message in
            guard let self else { return }
            self.testButton.isEnabled = true
            if let message {
                self.testResult.stringValue = "下行 " + message
                self.testResult.textColor = .labelColor
            } else {
                self.testResult.stringValue = "测速失败：当前链路无法下载测试数据"
                self.testResult.textColor = .systemRed
            }
        }
    }

    @objc private func resetStats() {
        monitor.resetStatistics()
        eventSignature = ""
        render()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
