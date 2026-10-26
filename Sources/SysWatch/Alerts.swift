import Foundation
import UserNotifications

struct Thresholds {
    var memPct = 90.0, swapGB = 8.0, cpuPct = 85.0, threads = 6000, diskFreeGB = 20.0, cooldownMin = 10.0

    static let defaults: [String: Any] = ["memPct": 90.0, "swapGB": 8.0, "cpuPct": 85.0, "threads": 6000, "diskFreeGB": 20.0, "cooldownMin": 10.0]

    static func load() -> Thresholds {
        let d = UserDefaults.standard
        return Thresholds(memPct: d.double(forKey: "memPct"), swapGB: d.double(forKey: "swapGB"), cpuPct: d.double(forKey: "cpuPct"),
                          threads: d.integer(forKey: "threads"), diskFreeGB: d.double(forKey: "diskFreeGB"), cooldownMin: d.double(forKey: "cooldownMin"))
    }
}

struct AlertEvent: Identifiable {
    let id = UUID()
    let date: Date
    let key: String
    let title: String
    let body: String
    let severity: Severity
}

final class Alerter: NSObject, UNUserNotificationCenterDelegate {
    private var lastFired: [String: Date] = [:]
    private var cpuStreak = 0
    var onQuit: ((pid_t) -> Void)?
    var onAskClaude: ((pid_t) -> Void)?
    var onAlert: ((AlertEvent) -> Void)?

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let quit = UNNotificationAction(identifier: "quit", title: "Quit process", options: [.destructive])
        let ask = UNNotificationAction(identifier: "ask", title: "Ask Claude to optimise", options: [.foreground])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "hog", actions: [quit], intentIdentifiers: []),
            UNNotificationCategory(identifier: "hog.claude", actions: [ask, quit], intentIdentifiers: []),
        ])
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Which alerts fire for this snapshot: memory (incl. swap), sustained CPU, threads, disk. Each key honours the cooldown.
    func evaluate(_ s: Snapshot, _ t: Thresholds, now: Date = Date()) -> [(key: String, title: String)] {
        var out: [(key: String, title: String)] = []
        if s.memUsedPct >= t.memPct || s.pressure >= 4 || s.swapUsedGB >= t.swapGB {
            out.append(("mem", "Memory \(Int(s.memUsedPct))% used, \(fmt(s.swapUsedGB)) GB swap"))
        }
        cpuStreak = s.cpuPct >= t.cpuPct ? cpuStreak + 1 : 0
        if cpuStreak >= 3 { out.append(("cpu", "CPU at \(Int(s.cpuPct))% for \(cpuStreak * pollSeconds)s")) }
        if s.threads >= t.threads { out.append(("threads", "\(s.threads) threads running")) }
        if s.diskFreeGB <= t.diskFreeGB { out.append(("disk", "Only \(fmt(s.diskFreeGB)) GB free on disk")) }
        return out.filter { item in
            if let last = lastFired[item.key], now.timeIntervalSince(last) < t.cooldownMin * 60 { return false }
            lastFired[item.key] = now
            return true
        }
    }

    func check(_ s: Snapshot, _ t: Thresholds, table: [pid_t: Proc]) {
        for (key, title) in evaluate(s, t) {
            if key == "disk" {
                let body = "Swap files alone take \(fmt(s.swapTotalGB)) GB. Clear caches or Downloads before it fills up."
                post(title: title, body: body, category: nil, pid: nil, id: key)
                onAlert?(AlertEvent(date: Date(), key: key, title: title, body: body, severity: .warn))
                continue
            }
            let byCPU = key == "cpu"
            guard let top = byCPU ? s.procs.max(by: { $0.cpu < $1.cpu }) : s.procs.max(by: { $0.footprintMB < $1.footprintMB }) else { continue }
            let claude = claudeAncestor(of: top.pid, in: table)
            var body = "Top: \(top.name) (pid \(top.pid)) " + (byCPU ? "\(Int(top.cpu))% CPU" : fmtMB(top.footprintMB))
            if let c = claude { body += " · started by Claude Code (pid \(c.pid))" }
            post(title: title, body: body, category: claude == nil ? "hog" : "hog.claude", pid: top.pid, id: key)
            onAlert?(AlertEvent(date: Date(), key: key, title: title, body: body, severity: .bad))
        }
    }

    /// `SysWatch --demo-alerts`: one notification of each kind with sample data, so the layout and buttons can be seen.
    /// No pid is attached, so the Quit / Ask Claude buttons on these do nothing.
    static let demoNotification = Notification.Name("local.syswatch.demo-alerts")

    func demo() {
        setup()
        printPermission()
        postSamples()
    }

    func printPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let name: String
            switch s.authorizationStatus {
            case .authorized: name = "authorized"
            case .provisional: name = "provisional (quiet, Notification Center only)"
            case .denied: name = "DENIED: turn SysWatch on in System Settings › Notifications"
            case .notDetermined: name = "NOT DETERMINED: macOS has not shown the permission prompt yet, or it was dismissed"
            @unknown default: name = "unknown"
            }
            print("notification permission: \(name); alerts \(s.alertSetting == .enabled ? "on" : "off"), banners \(s.alertStyle == .none ? "off" : "on")")
        }
    }

    func postSamples() {
        post(title: "Memory 94% used, 14 GB swap", body: "Top: Python (pid 6567) 7.7 GB · started by Claude Code (pid 2223)",
             category: "hog.claude", pid: nil, id: "demo.mem", subtitle: "Sample alert")
        post(title: "CPU at 92% for 9s", body: "Top: LogiPluginServiceNative (pid 3301) 55% CPU",
             category: "hog", pid: nil, id: "demo.cpu", subtitle: "Sample alert")
        post(title: "6120 threads running", body: "Top: Google Chrome Helper (Renderer) (pid 4092) 538 MB",
             category: "hog", pid: nil, id: "demo.threads", subtitle: "Sample alert")
        post(title: "Only 18 GB free on disk", body: "Swap files alone take 15 GB. Clear caches or Downloads before it fills up.",
             category: nil, pid: nil, id: "demo.disk", subtitle: "Sample alert")
    }

    func post(title: String, body: String, category: String?, pid: pid_t?, id: String, subtitle: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let subtitle { content.subtitle = subtitle }
        if let category { content.categoryIdentifier = category }
        if let pid { content.userInfo = ["pid": Int(pid)] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pid = response.notification.request.content.userInfo["pid"] as? Int {
            switch response.actionIdentifier {
            case "quit": onQuit?(pid_t(pid))
            case "ask": onAskClaude?(pid_t(pid))
            default: break
            }
        }
        completionHandler()
    }
}
