import Foundation

/// Average CPU/GPU use per group over a sliding window, for ranking the process list by
/// sustained demand instead of the last 2 s. Ticks are evenly spaced, so the mean is per tick:
/// a tick where a group was absent (idle, under the scan's minimum) counts as zero.
public struct UsageAverager: Sendable {
    public struct Average: Sendable {
        public let group: TargetGroup // as last seen
        public let cpu: Double
        public let gpu: Double?
        public var demand: Double { cpu + (gpu ?? 0) }
    }

    private struct Tick { let time: Date; let usage: [String: (cpu: Double, gpu: Double?)] }
    private var ticks: [Tick] = []
    private var lastSeen: [String: (group: TargetGroup, time: Date)] = [:]
    private let retention: TimeInterval

    /// `retention`: the longest window that will be asked for.
    public init(retention: TimeInterval) { self.retention = retention }

    public mutating func record(_ groups: [TargetGroup], at time: Date) {
        ticks.append(Tick(time: time, usage: Dictionary(groups.map { ($0.key, ($0.cpu, $0.gpu)) }, uniquingKeysWith: { a, _ in a })))
        for g in groups { lastSeen[g.key] = (g, time) }
        let cutoff = time.addingTimeInterval(-retention)
        ticks.removeAll { $0.time < cutoff }
        lastSeen = lastSeen.filter { $0.value.time >= cutoff }
    }

    public func averages(window: TimeInterval, now: Date) -> [String: Average] {
        let recent = ticks.filter { $0.time > now.addingTimeInterval(-window) }
        guard !recent.isEmpty else { return [:] }
        var cpu: [String: Double] = [:], gpu: [String: Double] = [:]
        for t in recent {
            for (k, u) in t.usage {
                cpu[k, default: 0] += u.cpu
                if let g = u.gpu { gpu[k, default: 0] += g }
            }
        }
        let n = Double(recent.count)
        var out: [String: Average] = [:]
        for (k, c) in cpu {
            guard let g = lastSeen[k]?.group else { continue }
            out[k] = Average(group: g, cpu: c / n, gpu: gpu[k].map { $0 / n })
        }
        return out
    }
}
