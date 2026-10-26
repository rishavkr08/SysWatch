import SwiftUI
import ServiceManagement

// MARK: - Severity colours

enum Severity: Int, Comparable {
    case ok, warn, bad
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    var color: Color { switch self { case .ok: .green; case .warn: .orange; case .bad: .red } }
    var nsColor: NSColor { switch self { case .ok: .systemGreen; case .warn: .systemOrange; case .bad: .systemRed } }
    /// Text colour: only problems get coloured, so normal rows stay quiet.
    var textColor: Color { self == .ok ? .primary : color }
}

/// Higher is worse: orange from 80% of the threshold, red at the threshold.
func severity(_ value: Double, over threshold: Double) -> Severity {
    value >= threshold ? .bad : value >= threshold * 0.8 ? .warn : .ok
}

/// Lower is worse (disk free): orange within 1.5× of the threshold, red at it.
func severity(_ value: Double, under threshold: Double) -> Severity {
    value <= threshold ? .bad : value <= threshold * 1.5 ? .warn : .ok
}

struct Levels {
    let cpu, mem, swap, threads, disk: Severity
    var overall: Severity { [cpu, mem, swap, threads, disk].max() ?? .ok }

    init(_ s: Snapshot, _ t: Thresholds) {
        cpu = severity(s.cpuPct, over: t.cpuPct)
        let pressure: Severity = s.pressure >= 4 ? .bad : s.pressure >= 2 ? .warn : .ok
        mem = max(severity(s.memUsedPct, over: t.memPct), pressure)
        swap = severity(s.swapUsedGB, over: t.swapGB)
        threads = severity(Double(s.threads), over: Double(t.threads))
        disk = severity(s.diskFreeGB, under: t.diskFreeGB)
    }
}

func pressureName(_ level: Int) -> String { level >= 4 ? "critical" : level >= 2 ? "warning" : "normal" }

/// Change over the last `samples` samples (20 samples = 60 s at 3 s polls).
func perMinute(_ hist: [Double], samples: Int) -> Double {
    guard hist.count >= 2 else { return 0 }
    return hist[hist.count - 1] - hist[max(0, hist.count - 1 - samples)]
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var sortByCPU = false
    @Published var status = ""
    @Published var alerts: [AlertEvent] = []
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var swapHist: [Double] = []
    @Published var diskHist: [Double] = []
    @Published var claudeCwd: [pid_t: String] = [:]   // Claude Code session pid → its project folder ("" while looking it up)
    private(set) var table: [pid_t: Proc] = [:]
    let sampler = Sampler()
    let alerter = Alerter()
    private var timer: Timer?

    init() {
        UserDefaults.standard.register(defaults: Thresholds.defaults)
        alerter.onQuit = { [weak self] pid in self?.quit(pid, force: false) }
        alerter.onAskClaude = { [weak self] pid in self?.askClaude(pid) }
        alerter.onAlert = { [weak self] e in
            guard let self else { return }
            alerts.append(e)
            if alerts.count > 50 { alerts.removeFirst(alerts.count - 50) }
        }
        alerter.setup()
        DistributedNotificationCenter.default().addObserver(forName: Alerter.demoNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.alerter.postSamples() }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var thresholds: Thresholds { Thresholds.load() }
    var levels: Levels { Levels(snap, thresholds) }
    var groups: [AppGroup] {
        let gs = groupProcs(snap.procs)
        return sortByCPU ? gs.sorted { $0.cpu > $1.cpu } : gs.sorted { $0.footprintMB > $1.footprintMB }
    }
    var swapPerMinute: Double { perMinute(swapHist, samples: 60 / pollSeconds) }
    var recentAlerts: Int { alerts.filter { $0.date > Date().addingTimeInterval(-600) }.count }

    func claude(for p: Proc) -> Proc? { claudeAncestor(of: p.pid, in: table) }
    func claude(for g: AppGroup) -> Proc? { g.procs.lazy.compactMap { self.claude(for: $0) }.first }
    func project(for claude: Proc) -> String? {
        guard let dir = claudeCwd[claude.pid], !dir.isEmpty else { return nil }
        return dir.split(separator: "/").last.map(String.init)
    }

    func tick() {
        let sampler = self.sampler
        DispatchQueue.global(qos: .utility).async {
            let s = sampler.snapshot()
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    private func apply(_ s: Snapshot) {
        snap = s
        table = Dictionary(s.procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        push(&cpuHist, s.cpuPct)
        push(&memHist, s.memUsedPct)
        push(&swapHist, s.swapUsedGB)
        push(&diskHist, s.diskFreeGB)
        alerter.check(s, thresholds, table: table)
        // Resolve the project folder of each Claude Code session once (lsof is slow enough to keep off the poll).
        let sessions = Set(s.procs.compactMap { claudeAncestor(of: $0.pid, in: table)?.pid })
        for pid in sessions where claudeCwd[pid] == nil {
            claudeCwd[pid] = ""
            DispatchQueue.global().async {
                let dir = cwd(of: pid)
                DispatchQueue.main.async { self.claudeCwd[pid] = dir }
            }
        }
    }

    private func push(_ h: inout [Double], _ v: Double) {
        h.append(v)
        if h.count > historySamples { h.removeFirst(h.count - historySamples) }
    }

    func quit(_ pid: pid_t, force: Bool) {
        let name = table[pid]?.name ?? "\(pid)"
        switch terminate(pid, force: force) {
        case .ok: status = "\(force ? "Force quit" : "Asked to quit") \(name) (pid \(pid))"
        case .needsAdmin:
            status = "\(name) belongs to another user, asking for an admin password…"
            DispatchQueue.global().async { terminateAsAdmin(pid, force: force) }
        case .failed(let e): status = "Could not quit \(name): \(e)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.tick() }
    }

    func quit(group g: AppGroup, force: Bool) {
        if g.procs.count == 1 { quit(g.procs[0].pid, force: force); return }
        var ok = 0, admin = 0
        for p in g.procs {
            switch terminate(p.pid, force: force) {
            case .ok: ok += 1
            case .needsAdmin: admin += 1
            case .failed: break
            }
        }
        status = "\(force ? "Force quit" : "Asked to quit") \(ok) of \(g.procs.count) \(g.key) processes"
            + (admin > 0 ? " · \(admin) belong to another user, expand the row to quit them one by one" : "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.tick() }
    }

    func askClaude(_ pid: pid_t) {
        guard let p = table[pid], let c = claude(for: p) else { status = "No Claude Code session owns pid \(pid)"; return }
        let snap = self.snap
        status = "Building prompt…"
        DispatchQueue.global().async {
            let msg = askClaudeToOptimise(p, claude: c, snap: snap)
            DispatchQueue.main.async { self.status = msg }
        }
    }
}

// MARK: - App

@main
struct SysWatchApp: App {
    @StateObject private var model = Model()

    init() {
        if CommandLine.arguments.contains("--check") { selfCheck(); exit(0) }
        if CommandLine.arguments.contains("--demo-alerts") {
            let a = Alerter()
            a.printPermission()
            // Notification Center only shows the app icon for the copy macOS launched, so hand the job to it when it is running.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.syswatch")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if running {
                DistributedNotificationCenter.default().postNotificationName(Alerter.demoNotification, object: nil, userInfo: nil, deliverImmediately: true)
                print("sample alerts sent to the running SysWatch")
            } else {
                a.setup()
                a.postSamples()
                print("SysWatch is not running, posted directly (the icon only shows when the installed app posts)")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(3))   // let the notification centre accept them before exiting
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(nsImage: statusImage(dot: model.levels.overall.nsColor,
                                       text: "\(Int(model.snap.cpuPct))% · \(Int(model.snap.memUsedPct))%"))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Panel

enum Tab: String, CaseIterable { case overview = "Overview", processes = "Processes", alerts = "Alerts" }

struct Panel: View {
    @ObservedObject var model: Model
    @AppStorage("memPct") private var memPct = 90.0
    @AppStorage("swapGB") private var swapGB = 8.0
    @AppStorage("cpuPct") private var cpuPct = 85.0
    @AppStorage("threads") private var threads = 6000
    @AppStorage("diskFreeGB") private var diskFreeGB = 20.0
    @AppStorage("cooldownMin") private var cooldownMin = 10.0
    @State private var tab: Tab = .overview
    @State private var showThresholds = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        // Fixed size on purpose: a MenuBarExtra window that grows with its content can outgrow the screen,
        // and when it then shrinks macOS keeps the bottom edge, leaving the panel floating mid-screen.
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .overview: OverviewTab(model: model)
                    case .processes: GroupsCard(model: model, limit: 15, title: "Processes by app", expandable: true)
                    case .alerts: AlertsTab(model: model)
                    }
                    if !model.status.isEmpty {
                        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if showThresholds { thresholdsCard }
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 560, height: 740)
    }

    var header: some View {
        HStack {
            Text("SysWatch").font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t == .alerts && model.recentAlerts > 0 ? "Alerts (\(model.recentAlerts))" : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 270)
            Spacer()
            Text("last 10 min").font(.caption).foregroundStyle(.secondary)
        }
    }

    var thresholdsCard: some View {
        Card {
            Text("Alert thresholds").fontWeight(.semibold)
            Stepper("Memory used ≥ \(Int(memPct))%", value: $memPct, in: 50...99, step: 1)
            Stepper("Swap used ≥ \(Int(swapGB)) GB", value: $swapGB, in: 1...64, step: 1)
            Stepper("CPU ≥ \(Int(cpuPct))% for \(3 * pollSeconds)s", value: $cpuPct, in: 30...100, step: 5)
            Stepper("Threads ≥ \(threads)", value: $threads, in: 1000...20000, step: 500)
            Stepper("Disk free ≤ \(Int(diskFreeGB)) GB", value: $diskFreeGB, in: 5...200, step: 5)
            Stepper("Repeat an alert at most every \(Int(cooldownMin)) min", value: $cooldownMin, in: 1...120, step: 1)
            Text("Orange = within 80% of a limit, red = over it.").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    var footer: some View {
        HStack {
            Button(showThresholds ? "Hide thresholds" : "Thresholds…") { showThresholds.toggle() }.buttonStyle(.link)
            Spacer()
            Toggle("Launch at login", isOn: $launchAtLogin).toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.status = "Login item: \(error.localizedDescription)" }
                }
            Spacer()
            Button("Quit SysWatch") { NSApp.terminate(nil) }.buttonStyle(.link).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @ObservedObject var model: Model

    var body: some View {
        let s = model.snap
        let lv = model.levels
        let diskUsed = s.diskTotalGB > 0 ? 1 - s.diskFreeGB / s.diskTotalGB : 0
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                RingCard(title: "CPU", fraction: s.cpuPct / 100, text: "\(Int(s.cpuPct))%", sev: lv.cpu,
                         sub: "\(Int((s.cpuPct / 100 * Double(s.cores)).rounded())) of \(s.cores) cores busy",
                         hist: model.cpuHist, range: 0...100)
                RingCard(title: "Memory", fraction: s.memUsedPct / 100, text: "\(Int(s.memUsedPct))%", sev: lv.mem,
                         sub: "\(fmt(s.memUsedGB)) of \(fmt(s.memTotalGB)) GB · pressure \(pressureName(s.pressure))",
                         hist: model.memHist, range: 0...100)
                RingCard(title: "Disk", fraction: diskUsed, text: "\(Int(diskUsed * 100))%", sev: lv.disk,
                         sub: "\(fmt(s.diskFreeGB)) GB free of \(fmt(s.diskTotalGB)) GB",
                         hist: model.diskHist.map { s.diskTotalGB > 0 ? (1 - $0 / s.diskTotalGB) * 100 : 0 }, range: 0...100)
            }
            MemoryCard(model: model)
            GroupsCard(model: model, limit: 5, title: "Top by \(model.sortByCPU ? "CPU" : "memory")", expandable: false)
            RecentAlertsCard(model: model)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct RingCard: View {
    let title: String
    let fraction: Double
    let text: String
    let sev: Severity
    let sub: String
    let hist: [Double]
    let range: ClosedRange<Double>

    var body: some View {
        Card {
            VStack(spacing: 6) {
                Ring(fraction: fraction, color: sev.color, text: text, textColor: sev.textColor)
                Text(title).fontWeight(.semibold)
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Sparkline(values: hist, color: sev.color, range: range).frame(width: 120, height: 24)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct Ring: View {
    let fraction: Double
    let color: Color
    let text: String
    let textColor: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 8)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(textColor)
        }
        .frame(width: 84, height: 84)
    }
}

/// Last 10 minutes, newest sample at the right edge; the line grows in from the right until the buffer is full.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                let n = max(values.count, historySamples)
                let span = max(range.upperBound - range.lowerBound, 0.0001)
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i + n - values.count) / CGFloat(n - 1)
                    let clamped = min(max(v, range.lowerBound), range.upperBound)
                    let y = 1.5 + (g.size.height - 3) * (1 - CGFloat((clamped - range.lowerBound) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

struct StackedBar: View {
    let segments: [(Double, Color)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle().fill(segments[i].1).frame(width: g.size.width * CGFloat(min(max(segments[i].0, 0), 1)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 12)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct MemoryCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let s = model.snap
        let total = max(s.memTotalGB, 0.001)
        let rate = model.swapPerMinute
        let swapSev = model.levels.swap
        Card {
            HStack {
                Text("Memory, \(fmt(s.memTotalGB)) GB").fontWeight(.semibold)
                Spacer()
                Text("\(s.procs.count) processes · \(s.threads) threads").font(.caption).foregroundStyle(model.levels.threads.textColor)
            }
            StackedBar(segments: [(s.appGB / total, .blue), (s.wiredGB / total, .gray), (s.compressedGB / total, .orange)])
            HStack(spacing: 14) {
                legend(.blue, "App \(fmt(s.appGB)) GB")
                legend(.gray, "Wired \(fmt(s.wiredGB)) GB")
                legend(.orange, "Compressed \(fmt(s.compressedGB)) GB")
                legend(Color.secondary.opacity(0.3), "Free \(fmt(s.freeGB)) GB")
            }
            .font(.caption)
            Divider()
            HStack {
                (Text("Swap \(fmt(s.swapUsedGB)) GB").fontWeight(.semibold).foregroundStyle(swapSev.textColor)
                 + Text("  in \(s.swapFiles) swap files · \(rateText(rate))").foregroundStyle(.secondary))
                    .font(.callout)
                Spacer()
                Sparkline(values: model.swapHist, color: swapSev.color,
                          range: 0...max(model.swapHist.max() ?? 1, model.thresholds.swapGB))
                    .frame(width: 90, height: 20)
            }
        }
    }

    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t)
        }
    }

    func rateText(_ r: Double) -> String {
        abs(r) < 0.05 ? "steady" : r > 0 ? "growing \(fmt(r)) GB per minute" : "shrinking \(fmt(-r)) GB per minute"
    }
}

// MARK: - Processes

struct GroupsCard: View {
    @ObservedObject var model: Model
    let limit: Int
    let title: String
    let expandable: Bool
    @State private var expanded: Set<String> = []

    var body: some View {
        let ram = max(model.snap.memTotalGB, 0.001)
        Card {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                if expandable {
                    Picker("", selection: $model.sortByCPU) {
                        Text("By memory").tag(false)
                        Text("By CPU").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                } else {
                    Text("bar = share of RAM · grouped by app").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.groups.prefix(limit)) { g in
                GroupRow(g: g, claude: model.claude(for: g), ramGB: ram, model: model,
                         expandable: expandable, expanded: expanded.contains(g.key)) { toggle(g.key) }
            }
        }
    }

    func toggle(_ k: String) {
        if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) }
    }
}

struct GroupRow: View {
    let g: AppGroup
    let claude: Proc?
    let ramGB: Double
    @ObservedObject var model: Model
    let expandable: Bool
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        // One app is a problem at ≥10% of RAM or ≥50% of a core; orange from 80% of that.
        let memSev = severity(g.footprintMB / 1024, over: max(ramGB * 0.10, 0.5))
        let cpuSev = severity(g.cpu, over: 50)
        let share = min(g.footprintMB / 1024 / ramGB, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if expandable {
                            Button(action: onToggle) { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(expanded ? "Hide processes" : "Show processes")
                        }
                        Text(g.key).fontWeight(memSev == .ok && cpuSev == .ok ? .medium : .semibold).lineLimit(1)
                    }
                    Text(subtitle).font(.caption2).foregroundStyle(subtitleColor).lineLimit(1)
                }
                .frame(width: 160, alignment: .leading)
                GeometryReader { geo in
                    Capsule().fill(memSev == .ok ? Color.secondary.opacity(0.45) : memSev.color)
                        .frame(width: max(2, geo.size.width * share))
                }
                .frame(height: 14)
                .background(Color.secondary.opacity(0.08), in: Capsule())
                Text(fmtMB(g.footprintMB)).monospacedDigit().fontWeight(memSev == .ok ? .regular : .semibold)
                    .foregroundStyle(memSev.textColor).frame(width: 60, alignment: .trailing)
                Text("\(Int(g.cpu))%").monospacedDigit().font(.caption).foregroundStyle(cpuSev.textColor).frame(width: 36, alignment: .trailing)
                Menu {
                    if claude != nil { Button("Ask Claude to optimise") { model.askClaude(g.heaviest.pid) } }
                    Button(g.procs.count > 1 ? "Quit all \(g.procs.count) processes" : "Quit") { model.quit(group: g, force: false) }
                    Button(g.procs.count > 1 ? "Force quit all" : "Force quit", role: .destructive) { model.quit(group: g, force: true) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Actions")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(g.procs.prefix(12)) { p in
                        HStack(spacing: 8) {
                            Text("pid \(p.pid)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Text(p.name).font(.caption).lineLimit(1).help(p.args)
                            Spacer()
                            Text(fmtMB(p.footprintMB)).font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("\(Int(p.cpu))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                            Button("Quit") { model.quit(p.pid, force: false) }.buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    if g.procs.count > 12 { Text("and \(g.procs.count - 12) more").font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.leading, 18)
            }
        }
    }

    var subtitle: String {
        if let c = claude { return "Claude session" + (model.project(for: c).map { " · \($0)" } ?? "") }
        var parts = [g.procs.count == 1 ? "pid \(g.heaviest.pid)" : "\(g.procs.count) processes"]
        if g.cpu >= 20 { parts.append("\(Int(g.cpu))% CPU") }
        return parts.joined(separator: " · ")
    }

    var subtitleColor: Color { claude != nil ? .indigo : g.cpu >= 50 ? .red : g.cpu >= 20 ? .orange : .secondary }
}

// MARK: - Alerts

struct RecentAlertsCard: View {
    @ObservedObject var model: Model
    var body: some View {
        Card {
            HStack {
                Text("Recent alerts").fontWeight(.semibold)
                Spacer()
                if model.alerts.isEmpty { Text("none yet").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(model.alerts.suffix(3).reversed()) { AlertRow(e: $0) }
        }
    }
}

struct AlertsTab: View {
    @ObservedObject var model: Model
    var body: some View {
        Card {
            HStack {
                Text("Alerts").fontWeight(.semibold)
                Spacer()
                Button("Clear") { model.alerts.removeAll() }.controlSize(.small).disabled(model.alerts.isEmpty)
            }
            if model.alerts.isEmpty {
                Text("No alerts yet. Limits are under Thresholds in the footer.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.alerts.suffix(20).reversed()) { AlertRow(e: $0) }
        }
    }
}

struct AlertRow: View {
    let e: AlertEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Circle().fill(e.severity.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.callout)
                Text(e.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }
}
