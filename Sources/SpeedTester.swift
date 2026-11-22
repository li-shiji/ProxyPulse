import Foundation

/// 通过当前代理链路做一次真实下载测速
final class SpeedTester: NSObject, URLSessionDataDelegate {

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startedAt: Date?
    private var received: Int = 0
    private var finished = false
    private var progressHandler: ((Double, Double) -> Void)?   // 已下载字节, 已用时
    private var finishHandler: ((String?) -> Void)?
    private var candidates: [String] = []
    private var redirects = 0
    private var lastProgressAt: Date = .distantPast

    private let maxDuration: TimeInterval = 6.0

    func isRunning() -> Bool { task != nil }

    func start(proxy: ProxySettings,
               progress: @escaping (Double, Double) -> Void,
               finish: @escaping (String?) -> Void) {
        cancel()
        finished = false
        received = 0
        redirects = 0
        progressHandler = progress
        finishHandler = finish
        startedAt = Date()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if proxy.isEnabled, let host = proxy.preferredHost {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: proxy.preferredPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: proxy.preferredPort,
            ]
        }

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        candidates = [
            "https://speed.cloudflare.com/__down?bytes=50000000",
            "https://cachefly.cachefly.net/10mb.test",
            "https://speedtest.tele2.net/10MB.zip",
        ]
        guard let url = candidates.first.map(URL.init(string:)) ?? nil else {
            finishWith(nil); return
        }
        task = session.dataTask(with: URLRequest(url: url))
        task?.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration) { [weak self] in
            self?.stopAndReport()
        }
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func stopAndReport() {
        guard !finished else { return }
        task?.cancel()
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil

        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        guard received > 0, elapsed > 0.4 else {
            finishWith(nil)
            return
        }
        finishWith(describe(bytes: received, seconds: elapsed))
    }

    private func describe(bytes: Int, seconds: Double) -> String {
        let bytesPerSecond = Double(bytes) / seconds
        let mbps = bytesPerSecond * 8 / 1_000_000
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f Mbps · 平均 %.2f MB/s · 样本 %.1f MB",
                      mbps, bytesPerSecond / 1_048_576, mb)
    }

    private func finishWith(_ message: String?) {
        guard !finished else { return }
        finished = true
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        let handler = finishHandler
        finishHandler = nil
        progressHandler = nil
        handler?(message)
    }

    private func tryNextCandidate() {
        redirects += 1
        guard redirects < candidates.count, let url = URL(string: candidates[redirects]) else {
            stopAndReport()
            return
        }
        task?.cancel()
        received = 0
        startedAt = Date()
        task = session?.dataTask(with: URLRequest(url: url))
        task?.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        // 限流到每 0.25 秒刷新一次，避免无用重绘
        guard Date().timeIntervalSince(lastProgressAt) > 0.25 else { return }
        lastProgressAt = Date()
        let bytes = received
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        DispatchQueue.main.async { [weak self] in
            self?.progressHandler?(Double(bytes), elapsed)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, received == 0 {
            tryNextCandidate()
            return
        }
        stopAndReport()
    }
}
