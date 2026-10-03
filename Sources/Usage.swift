import Foundation

struct LimitWindow: Codable, Identifiable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Double?
    var id: String { "\(windowDurationMins ?? 0)-\(resetsAt ?? 0)" }
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var title: String {
        guard let m = windowDurationMins else { return "Usage window" }
        if m == 10080 { return "Weekly" }
        if m % 60 == 0 { return "\(m / 60) hour" }
        return "\(m) minute"
    }
}
struct LimitBucket: Codable {
    var limitName: String?
    var primary: LimitWindow?
    var secondary: LimitWindow?
}
struct LimitsResponse: Codable {
    var rateLimits: LimitBucket?
    var rateLimitsByLimitId: [String: LimitBucket]?
    var windows: [(String, LimitWindow)] {
        let buckets = rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 } ?? rateLimits.map { ["codex": $0] } ?? [:]
        return buckets.keys.sorted().flatMap { key in
            let b = buckets[key]!
            return [b.primary, b.secondary].compactMap { $0 }.map { (b.limitName ?? key.capitalized, $0) }
        }
    }
}
struct AccountUsage: Codable {
    struct Summary: Codable { var lifetimeTokens: Int64?; var peakDailyTokens: Int64? }
    struct Day: Codable { var startDate: String; var tokens: Int64 }
    var summary: Summary?
    var dailyUsageBuckets: [Day]?
    var latestDay: Day? { dailyUsageBuckets?.max { $0.startDate < $1.startDate } }
}
struct LocalTokens {
    var total: Int64 = 0
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var recordedAt: Date?
}

// Provider boundary: future services can supply the same limits and account metrics.
protocol UsageProvider: AnyObject {
    func start(receive: @escaping (Int, Data?, String?) -> Void) throws
    func refresh()
    func stop()
}
final class CodexProvider: UsageProvider {
    private var process: Process?
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "usage.codex.rpc")
    private var buffer = Data()
    private var initialized = false
    private var receive: ((Int, Data?, String?) -> Void)?
    static func executable() -> String? {
        let paths = [ProcessInfo.processInfo.environment["CODEX_BINARY"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func start(receive: @escaping (Int, Data?, String?) -> Void) throws {
        guard let binary = Self.executable() else { throw NSError(domain: "Codex is not installed", code: 1) }
        self.receive = receive
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server", "--listen", "stdio://"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; process = p
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in self?.receive?(0, nil, "Codex connection stopped. Use Reconnect.") }
        try p.run()
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "token_usage_widget", "title": "Token Usage", "version": "1.0.0"], "capabilities": ["experimentalApi": true]]])
    }
    private func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? input?.write(contentsOf: data + Data([10]))
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let id = json["id"] as? Int ?? 0
            if id == 1 {
                if json["error"] != nil { receive?(0, nil, "Could not initialize Codex connection."); continue }
                initialized = true; send(["method": "initialized"]); request(); continue
            }
            if let error = json["error"] as? [String: Any] {
                receive?(id, nil, error["message"] as? String ?? "Usage unavailable"); continue
            }
            if let result = json["result"], let bytes = try? JSONSerialization.data(withJSONObject: result) { receive?(id, bytes, nil) }
            if json["method"] as? String == "account/rateLimits/updated", let params = json["params"], let bytes = try? JSONSerialization.data(withJSONObject: params) { receive?(2, bytes, nil) }
        }
    }
    private func request() {
        send(["id": 2, "method": "account/rateLimits/read"])
        send(["id": 3, "method": "account/usage/read"])
    }
    func refresh() { queue.async { [weak self] in if self?.initialized == true { self?.request() } } }
    func stop() { process?.terminationHandler = nil; if process?.isRunning == true { process?.terminate() }; process = nil }
    deinit { stop() }
}

// Read only token events. Session content and credentials are never copied or displayed.
final class SessionReader {
    private var cache: [URL: (Date, LocalTokens)] = [:]
    func latest() -> LocalTokens {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return LocalTokens() }
        var newest = LocalTokens()
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            // Only read recently active sessions; older files cannot be the newest activity.
            if modified < Date().addingTimeInterval(-7 * 86400) { continue }
            var value: LocalTokens
            if let cached = cache[url], cached.0 == modified { value = cached.1 }
            else {
                value = read(url); cache[url] = (modified, value)
            }
            if let date = value.recordedAt, date > (newest.recordedAt ?? .distantPast) { newest = value }
        }
        return newest
    }
    private func read(_ url: URL) -> LocalTokens {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return LocalTokens() }
        defer { try? handle.close() }
        var pending = Data(), latest = LocalTokens()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end]); pending.removeSubrange(...end)
                guard let x = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      x["type"] as? String == "event_msg", let p = x["payload"] as? [String: Any],
                      p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                      let t = info["total_token_usage"] as? [String: Any], let stamp = x["timestamp"] as? String else { continue }
                let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
                func n(_ k: String) -> Int64 { (t[k] as? NSNumber)?.int64Value ?? 0 }
                latest = LocalTokens(total: n("total_tokens"), input: n("input_tokens"), cached: n("cached_input_tokens"), output: n("output_tokens"), recordedAt: date)
            }
        }
        return latest
    }
}
