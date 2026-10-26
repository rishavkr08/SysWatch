import Foundation

private func check(_ ok: Bool, _ what: String) {
    if !ok { print("self-check FAILED: \(what)"); exit(1) }
}

/// `SysWatch --check`: the one runnable check for the non-trivial pure logic. Touches no system APIs.
func selfCheck() {
    let r = parseProc("  6567  2223   501  12.5 /opt/homebrew/bin/python3 -u -m reel_importer")
    check(r?.pid == 6567 && r?.ppid == 2223 && r?.uid == 501 && r?.cpu == 12.5 && r?.args == "/opt/homebrew/bin/python3 -u -m reel_importer", "ps line parse")
    check(parseProc("garbage line") == nil, "ps parse rejects junk")

    check(isClaudeCode("/Users/x/Library/Application Support/Claude/claude-code/2.1.308/abc/claude.app/Contents/MacOS/claude --output-format stream-json"), "desktop-bundled claude")
    check(isClaudeCode("node /Users/x/.nvm/versions/node/v24/bin/claude"), "npm claude via node")
    check(isClaudeCode("claude --resume abc"), "bare claude")
    check(!isClaudeCode("/Applications/Claude.app/Contents/MacOS/Claude"), "desktop app itself is not a session")
    check(!isClaudeCode("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer"), "helper is not a session")
    check(!isClaudeCode("/Applications/SysWatch.app/Contents/MacOS/SysWatch"), "we are not a session")

    func proc(_ pid: pid_t, _ ppid: pid_t, _ path: String, mb: Double = 0) -> Proc {
        Proc(pid: pid, ppid: ppid, uid: 501, cpu: 0, footprintMB: mb, threads: 0, args: path, path: path,
             name: String(path.split(separator: " ").first!.split(separator: "/").last ?? ""))
    }
    let table: [pid_t: Proc] = [
        1: proc(1, 0, "/sbin/launchd"),
        10: proc(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
        20: proc(20, 10, "/Users/x/Library/Application Support/Claude/claude-code/2.1.308/abc/claude.app/Contents/MacOS/claude"),
        30: proc(30, 20, "/bin/zsh -c python -m reel_importer"),
        40: proc(40, 30, "/opt/homebrew/bin/python3 -m reel_importer"),
        50: proc(50, 10, "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
    ]
    check(claudeAncestor(of: 40, in: table)?.pid == 20, "python → zsh → claude session")
    check(claudeAncestor(of: 50, in: table) == nil, "desktop helper has no session ancestor")
    check(claudeAncestor(of: 20, in: table) == nil, "the session itself has no session ancestor")

    check(projectSlug("/Users/me/Documents/My App.v2") == "-Users-me-Documents-My-App-v2", "project slug")

    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    check(groupKey(path: chrome, name: "Google Chrome Helper (Renderer)") == "Google Chrome", "helpers group under the outer app")
    check(groupKey(path: "/opt/homebrew/opt/mysql@8.0/bin/mysqld", name: "mysqld") == "mysqld", "plain binaries group by name")
    check(groupKey(path: "", name: "kernel_task") == "kernel_task", "no path falls back to name")
    let groups = groupProcs([proc(100, 1, chrome, mb: 300), proc(101, 100, chrome, mb: 500), proc(102, 1, "/usr/bin/top", mb: 5)])
    let g = groups.first { $0.key == "Google Chrome" }
    check(groups.count == 2 && g?.procs.count == 2 && g?.footprintMB == 800 && g?.heaviest.pid == 101, "group totals and heaviest member")

    // A mixed "node" group: the heaviest node (an editor helper) is not Claude's, a lighter one is.
    var mixed = table
    mixed[60] = proc(60, 1, "/usr/local/bin/node /editor/server.js", mb: 900)
    mixed[61] = proc(61, 30, "/usr/local/bin/node dev-server.js", mb: 300)   // 30 = zsh under Claude session 20
    mixed[62] = proc(62, 61, "/usr/local/bin/node worker.js", mb: 100)
    let node = groupProcs(Array(mixed.values)).first { $0.key == "node" }!
    check(node.heaviest.pid == 60, "heaviest node is the editor helper")
    check(claudeTarget(in: node, table: mixed)?.proc.pid == 61 && claudeTarget(in: node, table: mixed)?.claude.pid == 20,
          "Ask Claude targets the heaviest Claude-started member, not the heaviest member")
    let editorOnly = groupProcs([mixed[60]!]).first!
    check(claudeTarget(in: editorOnly, table: mixed) == nil, "no target when no member is Claude's")

    let a = Alerter()
    var t = Thresholds()
    t.cpuPct = 80
    var s = Snapshot()
    s.diskFreeGB = 100   // an empty snapshot has 0 GB free, which would trip the disk alert
    s.cpuPct = 95
    check(a.evaluate(s, t).isEmpty && a.evaluate(s, t).isEmpty, "cpu must be sustained before it alerts")
    check(a.evaluate(s, t).map(\.key) == ["cpu"], "third hot sample alerts")
    check(a.evaluate(s, t).isEmpty, "cooldown suppresses the repeat")
    s.memUsedPct = 99
    check(a.evaluate(s, t).map(\.key) == ["mem"], "memory alert fires independently of cpu cooldown")
    s.cpuPct = 10
    s.memUsedPct = 10
    s.swapUsedGB = 12
    check(a.evaluate(s, t, now: Date().addingTimeInterval(3600)).map(\.key) == ["mem"], "swap alone trips the memory alert after cooldown")

    check(perMinute([1, 2, 3, 4, 5], samples: 4) == 4, "rate over the last N samples")
    check(perMinute([5], samples: 4) == 0, "rate needs two samples")
    print("self-check OK")
}
