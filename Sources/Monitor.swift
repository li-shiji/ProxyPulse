import Foundation

// MARK: - 连接状态

enum LinkState: Equatable {
    case unknown
    case off
    case ok
    case unstable
    case tunnelBroken
    case lanDown
    case proxyDown

    var title: String {
        switch self {
        case .unknown: return "正在检测"
        case .off: return "代理未开启"
        case .ok: return "连接正常"
        case .unstable: return "网络不稳"
        case .tunnelBroken: return "隧道不通"
        case .lanDown: return "本地网络断开"
        case .proxyDown: return "代理进程无响应"
        }
    }

    var isHealthy: Bool { self == .ok }
    var isBroken: Bool { self == .tunnelBroken || self == .lanDown || self == .proxyDown }
}

// MARK: - 事件

struct ConnEvent: Identifiable {
    enum Severity { case bad, good, warn, info }
    let id = UUID()
    var time: Date
    var severity: Severity
    var title: String
    var detail: String
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(max(seconds, 0).rounded())
    if s < 60 { return "\(s) 秒" }
    if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
    return "\(s / 3600) 小时 \((s % 3600) / 60) 分"
}

func formatSpeed(_ bps: Double) -> (value: String, unit: String) {
    if bps < 1000 { return (String(format: "%.0f", bps), "B/s") }
    if bps < 1024 * 1024 { return (String(format: "%.0f", bps / 1024), "KB/s") }
    if bps < 1024 * 1024 * 1024 { return (String(format: "%.1f", bps / 1048576), "MB/s") }
    return (String(format: "%.2f", bps / 1073741824), "GB/s")
}

func formatCompactSpeed(_ bps: Double) -> String {
    if bps < 1000 { return "0" }
    if bps < 1024 * 1024 { return String(format: "%.0fK", bps / 1024) }
    if bps < 1024 * 1024 * 1024 { return String(format: "%.1fM", bps / 1048576) }
    return String(format: "%.1fG", bps / 1073741824)
}

// MARK: - 监控核心

final class Monitor {

    // 采样间隔
    private let sampleInterval: TimeInterval = 1.0      // 速率采样
    private let probeInterval: TimeInterval = 2.0       // 连通性探测
    private let configInterval: TimeInterval = 6.0      // 代理/路由刷新
    private let historyLength = 90                       // 图表保留 90 个点

    private let counter = InterfaceCounter()
    private let probeQueue = DispatchQueue(label: "proxypulse.probe")
    private var sampleTimer: DispatchSourceTimer?
    private var probeTimer: DispatchSourceTimer?
    private var configTimer: DispatchSourceTimer?

    // 对外状态（仅主线程读写）
    private(set) var state: LinkState = .unknown
    private(set) var latencyMs: Double?          // 海外出口延迟
    private(set) var domesticMs: Double?         // 国内对照延迟
    private(set) var domesticOK: Bool?
    private(set) var handshakeMs: Double?
    private(set) var jitterMs: Double = 0
    private(set) var lossRate: Double = 0
    private(set) var traffic = TrafficSample()
    private(set) var proxy = ProxySettings()
    private(set) var route = RouteInfo()
    private(set) var lanOK: Bool?
    private(set) var lanInterface: String?
    private(set) var localIP: String?
    private(set) var router: String?
    private(set) var probeMessage = ""
    private(set) var events: [ConnEvent] = []
    private(set) var historyTraffic: [TrafficSample] = []
    private(set) var historyLatency: [Double?] = []
    private(set) var brokenSince: Date?
    private(set) var stableSince: Date = Date()
    private(set) var totalOutages: Int = 0
    private(set) var totalDowntime: Double = 0
    private(set) var lastOutageDuration: Double?
    private(set) var isProbing = false

    var onUpdate: (() -> Void)?

    private var probeWindow: [Bool] = []
    private var recentLatencies: [Double] = []
    private var consecutiveFailures = 0
    private var lastHandshakeFailure: String?
    private var lastSpikeAt: Date = .distantPast
    private var lastLanCheck: Date = .distantPast
    private var firstProbeDone = false
    private var firstFailureAt: Date?

    // MARK: 生命周期

    func start() {
        refreshConfig()
        _ = counter.sample()   // 建立基线，避免首帧出现天文数字
        traffic = TrafficSample()

        let sampleSource = DispatchSource.makeTimerSource(queue: .main)
        sampleSource.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
        sampleSource.setEventHandler { [weak self] in self?.tick() }
        sampleSource.resume()
        sampleTimer = sampleSource

        scheduleNextProbe(after: 0)

        let configSource = DispatchSource.makeTimerSource(queue: .main)
        configSource.schedule(deadline: .now() + configInterval, repeating: configInterval)
        configSource.setEventHandler { [weak self] in self?.refreshConfig() }
        configSource.resume()
        configTimer = configSource

        log(.info, "开始监控", detail: "采样 1 秒 / 探测 2 秒")
    }

    func stop() {
        sampleTimer?.cancel(); sampleTimer = nil
        probeTimer?.cancel(); probeTimer = nil
        configTimer?.cancel(); configTimer = nil
    }

    func resetStatistics() {
        counter.resetTotals()
        historyTraffic.removeAll()
        historyLatency.removeAll()
        probeWindow.removeAll()
        recentLatencies.removeAll()
        consecutiveFailures = 0
        totalOutages = 0
        totalDowntime = 0
        lastOutageDuration = nil
        events.removeAll()
        stableSince = Date()
        log(.info, "统计已重置", detail: "")
        onUpdate?()
    }

    // MARK: 采样

    private func tick() {
        traffic = counter.sample()
        historyTraffic.append(traffic)
        if historyTraffic.count > historyLength { historyTraffic.removeFirst() }
        if firstProbeDone, historyLatency.count < historyTraffic.count {
            historyLatency.append(latencyMs)
        }
        if historyLatency.count > historyLength { historyLatency.removeFirst() }
        onUpdate?()
    }

    private func refreshConfig() {
        let newProxy = readSystemProxy()
        let newRoute = readDefaultRoute()
        let endpoint = readLANEndpoint()

        if newProxy != proxy || newRoute != route {
            proxy = newProxy
            route = newRoute
        }
        lanInterface = endpoint.ifName
        localIP = endpoint.localIP
        router = endpoint.router
        reevaluate()
        onUpdate?()
    }

    // MARK: 探测

    /// 链式调度：一次探测结束（无论成功或超时）后再安排下一次，
    /// 这样探测本身的耗时才不会把检测节奏拖长
    private func scheduleNextProbe(after delay: TimeInterval) {
        probeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.runProbe() }
        timer.resume()
        probeTimer = timer
    }

    private func runProbe() {
        guard !isProbing else { return }
        isProbing = true

        let proxySnapshot = proxy
        let routerSnapshot = router
        let needLanCheck = Date().timeIntervalSince(lastLanCheck) > 10
        let viaProxy: ProxySettings? = proxySnapshot.isEnabled ? proxySnapshot : nil

        probeQueue.async { [weak self] in
            guard let self else { return }
            var overseas = ProbeResult.fail("未执行")
            var domestic = ProbeResult.fail("未执行")
            let lock = NSLock()

            // 两路并行：海外出口 + 国内对照，用于区分「节点挂了」还是「家宽断了」
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                let result: ProbeResult
                if index == 0 {
                    result = probeHTTP(proxy: viaProxy,
                                       host: "connectivitycheck.gstatic.com",
                                       path: "/generate_204")
                } else {
                    result = probeHTTP(proxy: viaProxy, host: "www.baidu.com", path: "/")
                }
                lock.lock()
                if index == 0 { overseas = result } else { domestic = result }
                lock.unlock()
            }

            var lan: Bool? = nil
            if needLanCheck { lan = probeLAN(router: routerSnapshot) }

            DispatchQueue.main.async {
                self.apply(overseas: overseas, domestic: domestic,
                           lanResult: lan, checkLAN: needLanCheck)
            }
        }
    }

    private func apply(overseas probe: ProbeResult, domestic: ProbeResult,
                       lanResult: Bool?, checkLAN: Bool) {
        isProbing = false
        // 冷启动的第一次探测常常因为建连/解析偏慢而失败，不计入统计
        let isWarmupProbe = !firstProbeDone
        firstProbeDone = true
        if isWarmupProbe, !probe.success {
            probeMessage = probe.message
            onUpdate?()
            scheduleNextProbe(after: 0.3)
            return
        }
        if checkLAN {
            lanOK = lanResult
            lastLanCheck = Date()
        }

        domesticOK = domestic.success
        domesticMs = domestic.success ? domestic.responseMs : nil

        let proxyAlive = probe.handshakeMs > 0 || (probe.success && probe.responseMs > 0)
        if probe.success {
            latencyMs = probe.responseMs
            handshakeMs = probe.handshakeMs
            probeMessage = probe.message
            lastHandshakeFailure = nil
            if probe.responseMs > 3000, Date().timeIntervalSince(lastSpikeAt) > 20 {
                lastSpikeAt = Date()
                log(.warn, "海外响应很慢", detail: String(format: "单次请求耗时 %.1f 秒", probe.responseMs / 1000))
            }
            recentLatencies.append(probe.responseMs)
            if recentLatencies.count > 12 { recentLatencies.removeFirst() }
            consecutiveFailures = 0
            firstFailureAt = nil
        } else {
            if consecutiveFailures == 0 { firstFailureAt = Date() }
            consecutiveFailures += 1
            if !proxyAlive && proxy.isEnabled { lastHandshakeFailure = probe.message }
            if probe.handshakeMs > 0 { handshakeMs = probe.handshakeMs }
            probeMessage = probe.message
            latencyMs = nil
        }

        probeWindow.append(probe.success)
        if probeWindow.count > 6 { probeWindow.removeFirst() }
        let failures = probeWindow.filter { !$0 }.count
        lossRate = probeWindow.isEmpty ? 0 : Double(failures) / Double(probeWindow.count)

        if recentLatencies.count >= 3 {
            let avg = recentLatencies.reduce(0, +) / Double(recentLatencies.count)
            let variance = recentLatencies.map { pow($0 - avg, 2) }.reduce(0, +) / Double(recentLatencies.count)
            jitterMs = variance.squareRoot()
        }

        reevaluate()
        onUpdate?()
        scheduleNextProbe(after: 0.4)
    }

    // MARK: 状态判定

    private func reevaluate() {
        let tunnelActive = route.isTunnel || proxy.isEnabled
        var next: LinkState
        var reason = ""

        if !tunnelActive {
            next = .off
            reason = "系统未设置代理，也没有隧道接口"
        } else if !firstProbeDone {
            next = .unknown
            reason = "等待首次探测结果"
        } else if consecutiveFailures >= 2 {
            let proxyPortDead = (lastHandshakeFailure != nil) && proxy.isEnabled
            if proxyPortDead {
                next = .proxyDown
                reason = lastHandshakeFailure ?? "本地代理端口无响应"
            } else if lanOK == false || domesticOK == false {
                if lanOK == false {
                    next = .lanDown
                    reason = "网关无响应，本地网络可能已断开"
                } else {
                    next = .tunnelBroken
                    reason = "国内也不通，但局域网正常：出口链路异常"
                }
            } else {
                next = .tunnelBroken
                reason = "国内可通、海外不通：节点或规则异常"
            }
        } else if consecutiveFailures == 1 {
            next = .unstable
            reason = "最近一次探测失败：\(probeMessage)"
        } else if lossRate >= 0.2 {
            next = .unstable
            reason = String(format: "最近 %d 次探测丢 %.0f%%", probeWindow.count, lossRate * 100)
        } else {
            next = .ok
            reason = ""
        }

        let previous = state
        state = next

        if !next.isBroken, previous.isBroken {
            // 从「真断了」恢复到能通（含仍在抖动）
            if let since = brokenSince {
                let duration = Date().timeIntervalSince(since)
                lastOutageDuration = duration
                totalDowntime += duration
                log(.good, "已恢复", detail: "本次中断 \(formatDuration(duration))")
                brokenSince = nil
            }
            stableSince = Date()
        } else if next.isBroken, !previous.isBroken {
            totalOutages += 1
            brokenSince = firstFailureAt ?? Date()
            stableSince = Date()
            log(.bad, next.title, detail: reason)
        } else if next == .unstable, previous == .ok {
            log(.warn, "网络抖动", detail: reason)
            stableSince = Date()
        } else if next == .ok, previous == .off || previous == .unknown {
            log(.good, "连接已建立", detail: "隧道已就绪")
            stableSince = Date()
        } else if next == .off, previous != .off, previous != .unknown {
            log(.info, "代理已关闭", detail: "未检测到代理或隧道")
            brokenSince = nil
        }
    }

    // MARK: 工具

    private func log(_ severity: ConnEvent.Severity, _ title: String, detail: String) {
        events.insert(ConnEvent(time: Date(), severity: severity, title: title, detail: detail), at: 0)
        if events.count > 40 { events.removeLast() }
    }

    var stableDuration: Double {
        Date().timeIntervalSince(brokenSince ?? stableSince)
    }

    var trafficTotal: (rx: Double, tx: Double) {
        (counter.totalRx, counter.totalTx)
    }
}
