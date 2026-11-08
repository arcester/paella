import Darwin
import Foundation
import IOKit

/// A process identity that survives PID reuse: (pid, start time in µs since 1970).
public struct ProcessKey: Hashable, Sendable, Codable {
    public let pid: Int32
    public let start: UInt64
    public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
}

public enum ProcInfo {
    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    public static func key(_ pid: Int32) -> ProcessKey? {
        bsdInfo(pid).map { ProcessKey(pid: pid, start: UInt64($0.pbi_start_tvsec) * 1_000_000 + UInt64($0.pbi_start_tvusec)) }
    }

    /// True if `key.pid` is still the same process (not exited, not reused).
    public static func isAlive(_ key: ProcessKey) -> Bool { Self.key(key.pid) == key }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Total user+system CPU time in nanoseconds.
    static func cpuTimeNs(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        // rusage times are mach ticks on Apple Silicon.
        return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(n, 0))))
    }
}

public struct ProcessSample: Sendable, Identifiable {
    public let key: ProcessKey
    public var id: ProcessKey { key }
    public let name: String
    public let path: String
    /// CPU usage in cores (1.0 = one core fully busy).
    public let cpu: Double
    /// Share of GPU time (0…1), nil when per-process GPU stats are unavailable.
    public let gpu: Double?
}

public struct ProcessScan: Sendable {
    public let samples: [ProcessSample]
    public let gpuAvailable: Bool
}

/// Samples per-process CPU (rusage deltas) and GPU (IORegistry AGX user-client GPU time) every call.
public actor ProcessMonitor {
    private var lastCPU: [ProcessKey: UInt64] = [:]
    private var lastGPU: [ProcessKey: UInt64] = [:]
    private var lastTime: Date?

    public init() {}

    /// `keep`: processes to report even when (nearly) idle, e.g. the ones currently throttled.
    /// Processes below `minCPU` (cores) and `minGPU` (share) are left out unless in `keep`.
    public func scan(keep: Set<ProcessKey> = [], minCPU: Double = 0.05, minGPU: Double = 0.02) -> ProcessScan {
        let now = Date()
        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        lastTime = now
        let uid = getuid(), me = getpid()
        let gpuTimes = Self.gpuTimesByPid()
        var cpu: [ProcessKey: UInt64] = [:], gpu: [ProcessKey: UInt64] = [:]
        var samples: [ProcessSample] = []
        for pid in ProcInfo.allPids() where pid > 0 && pid != me {
            guard let info = ProcInfo.bsdInfo(pid), info.pbi_uid == uid, let ns = ProcInfo.cpuTimeNs(pid) else { continue }
            let key = ProcessKey(pid: pid, start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
            cpu[key] = ns
            let g = gpuTimes?[pid]
            if let g { gpu[key] = g }
            guard dt > 0.5 else { continue }
            let cpuRate = lastCPU[key].map { Double(ns &- $0) / (dt * 1e9) } ?? 0
            let gpuRate: Double? = gpuTimes == nil ? nil : (g.flatMap { g in lastGPU[key].map { Double(g &- $0) / (dt * 1e9) } } ?? 0)
            guard cpuRate > minCPU || (gpuRate ?? 0) > minGPU || keep.contains(key) else { continue }
            let path = ProcInfo.path(pid)
            let name = path.isEmpty ? ProcInfo.name(pid) : (path as NSString).lastPathComponent
            samples.append(ProcessSample(key: key, name: name, path: path, cpu: max(cpuRate, 0), gpu: gpuRate.map { min(max($0, 0), 1) }))
        }
        lastCPU = cpu
        lastGPU = gpu
        return ProcessScan(samples: samples, gpuAvailable: gpuTimes != nil)
    }

    /// Accumulated GPU nanoseconds per PID from the AGX user clients under IOAccelerator,
    /// the same source Activity Monitor uses. Nil when unreadable.
    static func gpuTimesByPid() -> [Int32: UInt64]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(accelerators) }
        var out: [Int32: UInt64] = [:]
        var clients = 0
        while case let acc = IOIteratorNext(accelerators), acc != 0 {
            var children: io_iterator_t = 0
            IORegistryEntryGetChildIterator(acc, kIOServicePlane, &children)
            IOObjectRelease(acc)
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                // "pid 1234, name"
                guard let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                    creator.hasPrefix("pid "),
                    let pid = Int32(creator.dropFirst(4).prefix { $0 != "," }) else { continue }
                clients += 1
                let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] ?? []
                out[pid, default: 0] += usage.reduce(0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
            }
            IOObjectRelease(children)
        }
        return clients > 0 ? out : nil
    }
}

// MARK: - Target selection (pure)

public struct TargetGroup: Sendable, Identifiable {
    public let key: String
    public var id: String { key }
    public let name: String
    public let members: [ProcessSample]
    /// Contains system components (or an unreadable path); never stopped.
    public let isProtected: Bool
    public var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
    public var gpu: Double? { members.contains { $0.gpu != nil } ? members.reduce(0) { $0 + ($1.gpu ?? 0) } : nil }
    /// The .app bundles its processes come from (several when same-named apps were merged).
    public var bundles: Set<String> { Set(members.compactMap { TargetSelector.bundle(of: $0.path) }) }
    /// Ranking for the "most demanding" list: CPU cores + GPU share.
    public var demand: Double { cpu + (gpu ?? 0) }
}

public struct SelectionPolicy: Sendable {
    public var cpuThreshold = 0.8 // cores
    public var gpuThreshold = 0.2 // share of GPU time
    /// Names the user marked as unlimited (group or process name, case-insensitive).
    public var exclusions: [String] = []
    public var knownGPUProcesses: [String] = []
    public var gpuAvailable = true
    public var excludedBundlePaths: [String] = [] // frontmost app, this app
    public var activeGroups: Set<String> = []
    public init() {}
}

public enum TargetSelector {
    /// Processes under these paths are system components; stopping them can freeze the session.
    static let protectedPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// Helpers live inside their app's bundle, so the outermost `.app` groups them with the app.
    /// Same-named apps share one group (e.g. Claude.app and Claude Code's claude.app): "Ilimitado"
    /// already matches by name, so two rows called "Claude" would be one choice shown twice.
    public static func group(for s: ProcessSample) -> (key: String, name: String) {
        if let bundle = bundle(of: s.path) {
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return ("app:" + name.lowercased(), name)
        }
        return ("\(s.key.pid)-\(s.key.start)", s.name)
    }

    /// Outermost .app containing `path`, if any.
    static func bundle(of path: String) -> String? {
        path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    }

    static func listed(_ name: String, in list: [String]) -> Bool {
        list.contains { !$0.isEmpty && name.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// True if the user marked this group (or one of its processes) as unlimited.
    public static func isExcluded(_ g: TargetGroup, by list: [String]) -> Bool {
        listed(g.name, in: list) || g.members.contains { listed($0.name, in: list) }
    }

    /// All sampled processes grouped by app, most demanding first.
    public static func groups(_ samples: [ProcessSample]) -> [TargetGroup] {
        Dictionary(grouping: samples) { group(for: $0).key }.map { key, members in
            TargetGroup(key: key, name: members.map { group(for: $0).name }.min()!, members: members, // "Claude" over "claude"
                        isProtected: members.contains { s in s.path.isEmpty || protectedPrefixes.contains { s.path.hasPrefix($0) } })
        }.sorted { $0.demand > $1.demand }
    }

    public static func select(_ groups: [TargetGroup], policy p: SelectionPolicy) -> [TargetGroup] {
        groups.filter { g in
            if g.isProtected || !g.bundles.isDisjoint(with: p.excludedBundlePaths) || isExcluded(g, by: p.exclusions) { return false }
            // Sticky: a limited (and E-core-demoted) group is starved, so its measured usage says
            // nothing about its demand. It stays a target until limiting ends.
            if p.activeGroups.contains(g.key) { return true }
            let knownHot = !p.gpuAvailable && g.cpu > 0.2 && isExcluded(g, by: p.knownGPUProcesses)
            return g.cpu > p.cpuThreshold || (g.gpu ?? 0) > p.gpuThreshold || knownHot
        }
    }
}
