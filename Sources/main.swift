import Cocoa
import SwiftUI

final class UsageModel: ObservableObject {
    @Published var limits: LimitsResponse?
    @Published var account: AccountUsage?
    @Published var local = LocalTokens()
    @Published var limitDate: Date?
    @Published var tokenDate: Date?
    @Published var error: String?
    @Published var tokenError: String?
    @Published var small = UserDefaults.standard.bool(forKey: "small")
    private var provider: UsageProvider = CodexProvider()
    private let reader = SessionReader()
    private let readerQueue = DispatchQueue(label: "usage.sessions", qos: .utility)
    private var timers: [Timer] = []
    func start() {
        connect()
        scan()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.provider.refresh() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() })
    }
    func connect() {
        provider.stop(); provider = CodexProvider(); error = nil
        do {
            try provider.start { [weak self] id, bytes, message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let message {
                        if id == 3 { self.tokenError = message } else { self.error = message }
                        return
                    }
                    guard let bytes else { return }
                    if id == 2, let value = try? JSONDecoder().decode(LimitsResponse.self, from: bytes) {
                        self.limits = value; self.limitDate = Date(); self.error = nil
                    }
                    if id == 3, let value = try? JSONDecoder().decode(AccountUsage.self, from: bytes) {
                        self.account = value; self.tokenDate = Date(); self.tokenError = nil
                    }
                }
            }
        } catch { self.error = "Install Codex and sign in, then Reconnect." }
    }
    func refresh() { provider.refresh(); scan() }
    private func scan() {
        readerQueue.async { [weak self] in
            guard let self else { return }
            let value = self.reader.latest()
            DispatchQueue.main.async { self.local = value }
        }
    }
    func stop() { timers.forEach { $0.invalidate() }; provider.stop() }
}

func count(_ n: Int64?) -> String { n.map { $0.formatted() } ?? "Unavailable" }
func shortCount(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n)/1_000_000) }
    if n >= 1000 { return String(format: "%.1fK", Double(n)/1000) }
    return "\(n)"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var panel: NSPanel!
    var status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: model.small ? 316 : 416, height: model.small ? 470 : 670), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Token Usage"; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.level = .normal; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: WidgetView(model: model, onResize: { [weak self] in self?.resize() }))
        panel.setFrameAutosaveName("TokenUsageWidget")
        if !panel.setFrameUsingName("TokenUsageWidget"), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 410, y: screen.visibleFrame.maxY - 530))
        }
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Token Usage")
        let menu = NSMenu()
        for (title, action) in [("Show / hide widget", #selector(toggle)), ("Small / medium size", #selector(resize)), ("Keep above windows", #selector(pin)), ("Refresh now", #selector(refresh)), ("Reconnect Codex", #selector(reconnect)), ("Quit", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        status.menu = menu; model.start()
    }
    @objc func toggle() { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }
    @objc func resize() {
        model.small.toggle(); UserDefaults.standard.set(model.small, forKey: "small")
        let size = NSSize(width: model.small ? 316 : 416, height: model.small ? 470 : 670)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top-size.height, width: size.width, height: size.height), display: true, animate: true)
    }
    @objc func pin(_ sender: NSMenuItem) { panel.level = panel.level == .floating ? .normal : .floating; sender.state = panel.level == .floating ? .on : .off }
    @objc func refresh() { model.refresh() }
    @objc func reconnect() { model.connect() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

if CommandLine.arguments.contains("--self-test") {
    let sample = Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":110,"windowDurationMins":300,"resetsAt":123},"secondary":null},"other":{"primary":{"usedPercent":-5,"windowDurationMins":60},"secondary":null}}}"#.utf8)
    let limits = try JSONDecoder().decode(LimitsResponse.self, from: sample)
    assert(limits.windows.count == 2)
    assert(limits.windows[0].1.remaining == 0 && limits.windows[1].1.remaining == 100)
    let usage = try JSONDecoder().decode(AccountUsage.self, from: Data(#"{"summary":{"lifetimeTokens":null,"peakDailyTokens":null},"dailyUsageBuckets":null}"#.utf8))
    assert(usage.latestDay == nil && usage.summary?.lifetimeTokens == nil)
    let local = SessionReader().latest()
    print("PASS: multiple windows, clamping, missing metrics, local token reader (\(local.total) tokens)")
} else if CommandLine.arguments.contains("--probe") {
    let provider = CodexProvider()
    var results = Set<Int>()
    try provider.start { id, bytes, error in
        DispatchQueue.main.async {
            if id == 2 || id == 3 {
                print("\(id == 2 ? "limits" : "tokens"): \(error ?? bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "No data")")
                results.insert(id)
                if results.count == 2 { provider.stop(); exit(0) }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { provider.stop(); print("Probe timed out"); exit(1) }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
