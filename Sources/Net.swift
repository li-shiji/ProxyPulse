import Foundation
import Darwin

// MARK: - 进程调用

@discardableResult
func runCommand(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - 网卡流量统计

struct TrafficSample {
    var rx: Double = 0          // 字节/秒
    var tx: Double = 0

    static func + (a: TrafficSample, b: TrafficSample) -> TrafficSample {
        TrafficSample(rx: a.rx + b.rx, tx: a.tx + b.tx)
    }
}

/// 通过 getifaddrs 读取物理网卡（en*）的累计字节，取差值得到实时速率。
/// 只统计物理网卡可以避免 TUN 接口与真实链路的重复计数。
final class InterfaceCounter {
    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastTimestamp: TimeInterval = 0
    private(set) var totalRx: Double = 0
    private(set) var totalTx: Double = 0

    var activeInterface: String?

    func sample() -> TrafficSample {
        let now = Date().timeIntervalSince1970
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]

        var listPtr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&listPtr) == 0, let first = listPtr {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let p = cursor {
                let ifa = p.pointee
                if let addr = ifa.ifa_addr,
                   addr.pointee.sa_family == UInt8(AF_LINK),
                   let raw = ifa.ifa_data {
                    let name = String(cString: ifa.ifa_name)
                    if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                        let d = raw.assumingMemoryBound(to: if_data.self).pointee
                        current[name] = (d.ifi_ibytes, d.ifi_obytes)
                    }
                }
                cursor = ifa.ifa_next
            }
            freeifaddrs(listPtr)
        }

        for (name, counters) in current where name.hasPrefix("en") {
            if let prev = previous[name] {
                // 32 位计数器会回绕，用 &- 做无符号差值
                rxBytes &+= UInt64(counters.rx &- prev.rx)
                txBytes &+= UInt64(counters.tx &- prev.tx)
            }
        }
        previous = current

        let dt = lastTimestamp > 0 ? max(now - lastTimestamp, 0.25) : 1.0
        lastTimestamp = now
        totalRx += Double(rxBytes)
        totalTx += Double(txBytes)
        return TrafficSample(rx: Double(rxBytes) / dt, tx: Double(txBytes) / dt)
    }

    func resetTotals() {
        totalRx = 0
        totalTx = 0
    }
}

// MARK: - 系统代理

struct ProxySettings: Equatable {
    var httpHost: String?
    var httpPort: Int = 0
    var socksHost: String?
    var socksPort: Int = 0

    var isEnabled: Bool { httpHost != nil || socksHost != nil }

    var display: String {
        if let h = httpHost, httpPort > 0 { return "\(h):\(httpPort)" }
        if let h = socksHost, socksPort > 0 { return "\(h):\(socksPort)" }
        return "未设置"
    }

    var preferredHost: String? { httpHost ?? socksHost }
    var preferredPort: Int { httpHost != nil ? httpPort : socksPort }
}

func readSystemProxy() -> ProxySettings {
    // 调试用：模拟一个坏掉的代理端口
    if ProcessInfo.processInfo.environment["PROXYPULSE_NO_PROXY"] != nil {
        return ProxySettings()
    }
    if let override = ProcessInfo.processInfo.environment["PROXYPULSE_PROXY_OVERRIDE"] {
        if let colon = override.lastIndex(of: ":") {
            let host = String(override[override.startIndex..<colon])
            let port = Int(override[override.index(after: colon)...]) ?? 0
            if !host.isEmpty, port > 0 {
                return ProxySettings(httpHost: host, httpPort: port)
            }
        }
    }
    let output = runCommand("/usr/sbin/scutil", ["--proxy"])
    let known: Set<String> = ["HTTPEnable", "HTTPProxy", "HTTPPort",
                              "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                              "SOCKSEnable", "SOCKSProxy", "SOCKSPort"]
    var values: [String: String] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, known.contains(parts[0]) else { continue }
        values[parts[0]] = parts[1]
    }

    var settings = ProxySettings()
    func pick(_ enable: String, _ hostKey: String, _ portKey: String) -> (String, Int)? {
        guard values[enable] == "1",
              let host = values[hostKey], !host.isEmpty,
              let port = Int(values[portKey] ?? ""), port > 0 else { return nil }
        return (host, port)
    }
    if let (h, p) = pick("HTTPEnable", "HTTPProxy", "HTTPPort") {
        settings.httpHost = h
        settings.httpPort = p
    } else if let (h, p) = pick("HTTPSEnable", "HTTPSProxy", "HTTPSPort") {
        settings.httpHost = h
        settings.httpPort = p
    }
    if let (h, p) = pick("SOCKSEnable", "SOCKSProxy", "SOCKSPort") {
        settings.socksHost = h
        settings.socksPort = p
    }
    return settings
}

// MARK: - 默认路由

struct RouteInfo: Equatable {
    var interface: String?
    var gateway: String?

    var isTunnel: Bool { (interface ?? "").hasPrefix("utun") }
    var display: String { interface ?? "—" }
}

func readDefaultRoute() -> RouteInfo {
    if ProcessInfo.processInfo.environment["PROXYPULSE_NO_TUNNEL"] != nil {
        return RouteInfo()
    }
    let output = runCommand("/sbin/route", ["-n", "get", "default"])
    var info = RouteInfo()
    for line in output.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("interface:") {
            info.interface = trimmed.replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("gateway:") {
            info.gateway = trimmed.replacingOccurrences(of: "gateway:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return info
}

/// 主用物理网卡的本地 IPv4 与网关
func readLANEndpoint() -> (ifName: String?, localIP: String?, router: String?) {
    var ifName: String?
    var localIP: String?
    var listPtr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&listPtr) == 0, let first = listPtr {
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty && ip != "0.0.0.0" {
                        ifName = name
                        localIP = ip
                        break
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        freeifaddrs(listPtr)
    }
    var router: String?
    if let name = ifName {
        let out = runCommand("/usr/sbin/ipconfig", ["getoption", name, "router"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty, !out.contains(" ") { router = out }
    }
    return (ifName, localIP, router)
}

// MARK: - 原始套接字探测

enum ConnectOutcome {
    case connected(latencyMs: Double)
    case refused          // 端口主动拒绝 → 主机是活的
    case timeout
    case failed(String)
}

final class RawSocket {
    private(set) var fd: Int32 = -1

    deinit { closeSocket() }

    func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval) -> ConnectOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let head = result else {
            return .failed("域名解析失败")
        }
        defer { freeaddrinfo(result) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        var lastError = "无法连接"
        while let ai = node {
            let info = ai.pointee
            let s = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if s >= 0 {
                var on: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

                let started = Date()
                let rc = Darwin.connect(s, info.ai_addr, info.ai_addrlen)
                if rc == 0 {
                    fd = s
                    return .connected(latencyMs: Date().timeIntervalSince(started) * 1000)
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&pfd, 1, Int32(timeout * 1000))
                    if ready > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 {
                            fd = s
                            return .connected(latencyMs: Date().timeIntervalSince(started) * 1000)
                        }
                        close(s)
                        if err == ECONNREFUSED { return .refused }
                        lastError = "连接错误 \(err)"
                    } else {
                        close(s)
                        if ready == 0 { return .timeout }
                        lastError = "连接超时"
                    }
                } else {
                    let e = errno
                    close(s)
                    if e == ECONNREFUSED { return .refused }
                    lastError = "连接错误 \(e)"
                }
            }
            node = info.ai_next
        }
        return .failed(lastError)
    }

    func write(_ data: Data, timeout: TimeInterval) -> Bool {
        guard fd >= 0 else { return false }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
            let n = bytes.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// 读到出现指定标记或超时
    func read(until marker: String, timeout: TimeInterval) -> String? {
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let remaining = max(deadline.timeIntervalSinceNow, 0.01)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(remaining * 1000))
            if ready <= 0 { break }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 16384 { break }
            if let text = String(data: buffer, encoding: .utf8), text.contains(marker) {
                return text
            }
        }
        return String(data: buffer, encoding: .utf8)
    }
}

// MARK: - 探针

struct ProbeResult {
    var success: Bool
    var handshakeMs: Double = 0     // 本地代理握手耗时
    var responseMs: Double = 0      // 完整 HTTP 响应耗时
    var message: String = ""

    static func fail(_ msg: String, handshake: Double = 0) -> ProbeResult {
        ProbeResult(success: false, handshakeMs: handshake, responseMs: 0, message: msg)
    }
}

/// 通用 HTTP 探针：给定了代理就走代理，否则直连（TUN 模式下由隧道接管）。
/// 同时验证「代理端口是否活着」与「链路是否真能拿到数据」。
func probeHTTP(proxy: ProxySettings?, host: String, port: UInt16 = 80,
               path: String = "/", timeout: TimeInterval = 3.5) -> ProbeResult {
    let sock = RawSocket()
    let started = Date()

    var connectHost = host
    var connectPort = port
    var request: String
    if let proxy, let proxyHost = proxy.preferredHost, proxy.preferredPort > 0 {
        connectHost = proxyHost
        connectPort = UInt16(proxy.preferredPort)
        request = "GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: ProxyPulse\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    } else {
        request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: ProxyPulse\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    }

    switch sock.connect(host: connectHost, port: connectPort, timeout: 1.2) {
    case .connected(let ms):
        guard sock.write(Data(request.utf8), timeout: 2.0) else {
            return ProbeResult.fail("代理已连接但写入失败", handshake: ms)
        }
        let reply = sock.read(until: "\r\n\r\n", timeout: timeout)
        let elapsed = Date().timeIntervalSince(started) * 1000
        guard let text = reply, !text.isEmpty else {
            return ProbeResult.fail("隧道无响应", handshake: ms)
        }
        let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
        guard firstLine.hasPrefix("HTTP/") else {
            return ProbeResult.fail("响应被中断", handshake: ms)
        }
        let codeText = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let code = Int(codeText) ?? 0
        if code >= 200, code < 400 {
            return ProbeResult(success: true, handshakeMs: ms, responseMs: elapsed, message: "正常")
        }
        if code >= 500 {
            return ProbeResult.fail("上游返回 \(code)", handshake: ms)
        }
        return ProbeResult.fail("返回状态 \(code)", handshake: ms)
    case .refused:
        sock.closeSocket()
        return .fail("代理端口未监听")
    case .timeout:
        sock.closeSocket()
        return .fail("代理端口无响应")
    case .failed(let msg):
        sock.closeSocket()
        return .fail(msg)
    }
}

/// 不经过代理的直连探测
func probeDirect(timeout: TimeInterval = 3.5) -> ProbeResult {
    probeHTTP(proxy: nil, host: "connectivitycheck.gstatic.com",
              path: "/generate_204", timeout: timeout)
}

/// 局域网健康度：能连上（或被拒绝）都说明链路正常，只有超时才算本地网络坏了
func probeLAN(router: String?, timeout: TimeInterval = 1.0) -> Bool? {
    guard let router, !router.isEmpty else { return nil }
    let sock = RawSocket()
    let outcome = sock.connect(host: router, port: 80, timeout: timeout)
    sock.closeSocket()
    switch outcome {
    case .connected, .refused: return true
    case .timeout, .failed: return false
    }
}
