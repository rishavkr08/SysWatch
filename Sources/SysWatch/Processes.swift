import Foundation
import Darwin

/// True when `args` is a Claude Code CLI process: the desktop-bundled binary, the native CLI, or the npm cli.
/// Case-sensitive on purpose: the desktop app's own "Claude" / "Claude Helper" processes must not match.
func isClaudeCode(_ args: String) -> Bool {
    let head = args.split(separator: " ", maxSplits: 2).prefix(2)
    return head.contains { $0 == "claude" || $0.hasSuffix("/claude") } || args.contains("claude-code/cli.js")
}

/// Nearest Claude Code ancestor of `pid`, walking the parent chain.
func claudeAncestor(of pid: pid_t, in table: [pid_t: Proc]) -> Proc? {
    var cur = table[pid]?.ppid
    var hops = 0
    while let p = cur, p > 1, hops < 32, let proc = table[p] {
        if isClaudeCode(proc.args) { return proc }
        cur = proc.ppid
        hops += 1
    }
    return nil
}

func cwd(of pid: pid_t) -> String {
    // `lsof -Fn` prints "p<pid>" then "n<path>"
    shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"])
        .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
}

/// Claude Code keeps transcripts in ~/.claude/projects/<cwd with every non-alphanumeric char turned into "-">/<session>.jsonl
func projectSlug(_ cwd: String) -> String { String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }

func latestSessionID(cwd: String) -> String? {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(projectSlug(cwd))")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let dated = files.filter { $0.pathExtension == "jsonl" }
        .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
    return dated.max { $0.1 < $1.1 }?.0.deletingPathExtension().lastPathComponent
}

enum KillResult { case ok, needsAdmin, failed(String) }

func terminate(_ pid: pid_t, force: Bool) -> KillResult {
    if kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .ok }
    return errno == EPERM ? .needsAdmin : .failed(String(cString: strerror(errno)))
}

/// For root-owned processes. Blocks until the password dialog closes, so call it off the main thread.
func terminateAsAdmin(_ pid: pid_t, force: Bool) {
    // ponytail: osascript gives us the system password prompt for free; no privileged helper or XPC service.
    shell("/usr/bin/osascript", ["-e", "do shell script \"kill -\(force ? 9 : 15) \(pid)\" with administrator privileges"])
}
