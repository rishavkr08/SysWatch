import Foundation
import Darwin

let gb = 1_073_741_824.0
let pollSeconds = 3
let historySamples = 200   // 10 minutes at 3 s

func fmt(_ x: Double) -> String { String(format: x >= 10 ? "%.0f" : "%.1f", x) }
func fmtMB(_ mb: Double) -> String { mb >= 1024 ? "\(fmt(mb / 1024)) GB" : "\(Int(mb)) MB" }

struct Proc: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let cpu: Double          // percent, as reported by ps
    let footprintMB: Double  // physical footprint: the "Memory" column in Activity Monitor
    let threads: Int
    let args: String         // full command line
    let path: String         // executable path ("" when not readable)
    let name: String         // executable basename
    var id: pid_t { pid }
}

struct Snapshot {
    var cpuPct = 0.0, cores = 1
    var memUsedPct = 0.0, memUsedGB = 0.0, memTotalGB = 0.0
    var appGB = 0.0, wiredGB = 0.0, compressedGB = 0.0, freeGB = 0.0
    var swapUsedGB = 0.0, swapTotalGB = 0.0, swapFiles = 0
    var pressure = 1          // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    var threads = 0
    var diskFreeGB = 0.0, diskTotalGB = 0.0
    var procs: [Proc] = []
}

/// Processes grouped by the app bundle they belong to (Chrome's 41 helpers become one row).
struct AppGroup: Identifiable {
    let key: String
    let procs: [Proc]
    var id: String { key }
    var footprintMB: Double { procs.reduce(0) { $0 + $1.footprintMB } }
    var cpu: Double { procs.reduce(0) { $0 + $1.cpu } }
    var threads: Int { procs.reduce(0) { $0 + $1.threads } }
    var heaviest: Proc { procs.max { $0.footprintMB < $1.footprintMB } ?? procs[0] }
}

/// Outermost ".app" bundle name in `path`, else the executable name.
func groupKey(path: String, name: String) -> String {
    for comp in path.split(separator: "/") where comp.hasSuffix(".app") { return String(comp.dropLast(4)) }
    return name
}

func groupProcs(_ procs: [Proc]) -> [AppGroup] {
    Dictionary(grouping: procs, by: { groupKey(path: $0.path, name: $0.name) })
        .map { AppGroup(key: $0.key, procs: $0.value.sorted { $0.footprintMB > $1.footprintMB }) }
}

/// Parses one line of `ps -Axww -o pid=,ppid=,uid=,%cpu=,args=`. Pure, so it is covered by the self-check.
func parseProc(_ line: String) -> (pid: pid_t, ppid: pid_t, uid: uid_t, cpu: Double, args: String)? {
    let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
    guard parts.count == 5, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]),
          let uid = uid_t(parts[2]), let cpu = Double(parts[3]) else { return nil }
    return (pid, ppid, uid, cpu, String(parts[4]))
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func pidPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

func footprintMB(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
}

func threadCount(_ pid: pid_t) -> Int {
    var ti = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size ? Int(ti.pti_threadnum) : 0
}

final class Sampler {
    private var lastTicks: (busy: Double, total: Double)?

    func snapshot() -> Snapshot {
        var s = Snapshot()
        s.cpuPct = cpuPercent()
        s.cores = ProcessInfo.processInfo.activeProcessorCount
        (s.memUsedPct, s.memUsedGB, s.memTotalGB, s.appGB, s.wiredGB, s.compressedGB) = memory()
        s.freeGB = max(s.memTotalGB - s.memUsedGB, 0)
        (s.swapUsedGB, s.swapTotalGB) = swap()
        s.swapFiles = swapFileCount()
        s.pressure = pressureLevel()
        (s.diskFreeGB, s.diskTotalGB) = disk()
        s.procs = processes()
        s.threads = s.procs.reduce(0) { $0 + $1.threads }
        return s
    }

    func cpuPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let busy = Double(info.cpu_ticks.0) + Double(info.cpu_ticks.1) + Double(info.cpu_ticks.3)  // user + system + nice
        let total = busy + Double(info.cpu_ticks.2)                                                 // + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return (busy - last.busy) / (total - last.total) * 100
    }

    /// Activity Monitor's split: App (internal minus purgeable), Wired, Compressed; Memory Used is their sum.
    func memory() -> (pct: Double, usedGB: Double, totalGB: Double, appGB: Double, wiredGB: Double, compressedGB: Double) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return (0, 0, total / gb, 0, 0, 0) }
        let page = Double(vm_kernel_page_size)
        let app = max(Double(vm.internal_page_count) - Double(vm.purgeable_count), 0) * page
        let wired = Double(vm.wire_count) * page
        let compressed = Double(vm.compressor_page_count) * page
        let used = app + wired + compressed
        return (used / total * 100, used / gb, total / gb, app / gb, wired / gb, compressed / gb)
    }

    func swap() -> (used: Double, total: Double) {
        var xsu = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsu, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(xsu.xsu_used) / gb, Double(xsu.xsu_total) / gb)
    }

    func swapFileCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Volumes/VM")) ?? []).filter { $0.hasPrefix("swapfile") }.count
    }

    func pressureLevel() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Int(level)
    }

    func disk() -> (free: Double, total: Double) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / gb, Double(v?.volumeTotalCapacity ?? 0) / gb)
    }

    func processes() -> [Proc] {
        // ponytail: one `ps` every poll instead of KERN_PROCARGS2 parsing; ~30 ms, and it gives us args + %cpu for free.
        shell("/bin/ps", ["-Axww", "-o", "pid=,ppid=,uid=,%cpu=,args="]).split(separator: "\n").compactMap { line in
            guard let r = parseProc(String(line)) else { return nil }
            let path = pidPath(r.pid)
            let name = (path.isEmpty ? String(r.args.split(separator: " ").first ?? "?") : path).split(separator: "/").last.map(String.init) ?? "?"
            return Proc(pid: r.pid, ppid: r.ppid, uid: r.uid, cpu: r.cpu, footprintMB: footprintMB(r.pid),
                        threads: threadCount(r.pid), args: r.args, path: path, name: name)
        }
    }
}
