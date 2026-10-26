import AppKit

let claudeBundleID = "com.anthropic.claudefordesktop"

func optimisePrompt(for p: Proc, claudePID: pid_t, cwd: String, sessionID: String?, snap: Snapshot) -> String {
    let session = sessionID.map { " (session \($0))" } ?? ""
    return """
    A process you started is making this Mac lag. Please deal with it.

    Process: \(p.name) (pid \(p.pid)), \(fmt(p.footprintMB / 1024)) GB memory footprint, \(Int(p.cpu))% CPU, \(p.threads) threads
    Command: \(p.args)
    Started by: your Claude Code session (pid \(claudePID)) in \(cwd)\(session)
    Machine right now: memory \(Int(snap.memUsedPct))% used (\(fmt(snap.memUsedGB)) of \(fmt(snap.memTotalGB)) GB), \(fmt(snap.swapUsedGB)) GB swap in use, CPU \(Int(snap.cpuPct))%, \(fmt(snap.diskFreeGB)) GB disk free

    1. If it is safe, stop or pause it now so the machine recovers.
    2. Find out why it needs this much memory/CPU: what it loads into memory, batch or segment sizes, worker counts, model sizes.
    3. Make it lighter so it fits alongside normal desktop use on a \(Int(snap.memTotalGB.rounded())) GB machine: stream instead of loading everything, smaller segments or batches, fewer workers, a lighter model, or run it on a server.
    4. Re-run it and confirm its peak footprint stays under \(Int(snap.memTotalGB / 4)) GB. Report what you changed.
    """
}

/// Copies an optimisation prompt for `p` to the clipboard and brings Claude to the front. Returns a status line.
func askClaudeToOptimise(_ p: Proc, claude: Proc, snap: Snapshot) -> String {
    let dir = cwd(of: claude.pid)
    let text = optimisePrompt(for: p, claudePID: claude.pid, cwd: dir, sessionID: latestSessionID(cwd: dir), snap: snap)
    let project = dir.split(separator: "/").last.map(String.init) ?? "?"
    DispatchQueue.main.async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    return "Prompt copied. Paste it into the Claude session working in \(project)."
}
