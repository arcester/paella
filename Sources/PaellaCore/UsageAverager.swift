import Foundation

/// Smoothed CPU/GPU use per group, and the highest smoothed value reached within a window, for
/// ranking the process list by real bursts of work: a spike shorter than the smoothing time barely
/// counts, but a minute at full load ranks high for the whole window. Ticks are evenly spaced, so a
/// mean is per tick: a tick where a group was absent (idle, under the scan's minimum) counts as zero.
public struct UsageAverager: Sendable {
    public struct Usage: Sendable {
        public let group: TargetGroup // as last seen
        /// Mean over the last `smoothing` seconds.
        public let cpu: Double
        public let gpu: Double?
        /// The smoothed values at the tick where their sum peaked within the window.
        public let peakCPU: Double
        public let peakGPU: Double?
        public var peakDemand: Double { peakCPU + (peakGPU ?? 0) }
    }

    private struct Tick { let time: Date; let usage: [String: (cpu: Double, gpu: Double?)] }
    private var ticks: [Tick] = []
    private var lastSeen: [String: (group: TargetGroup, time: Date)] = [:]
    private let retention: TimeInterval

    /// `retention`: the longest window plus smoothing that will be asked for.
    public init(retention: TimeInterval) { self.retention = retention }

    public mutating func record(_ groups: [TargetGroup], at time: Date) {
        ticks.append(Tick(time: time, usage: Dictionary(groups.map { ($0.key, ($0.cpu, $0.gpu)) }, uniquingKeysWith: { a, _ in a })))
        for g in groups { lastSeen[g.key] = (g, time) }
        let cutoff = time.addingTimeInterval(-retention)
        ticks.removeAll { $0.time < cutoff }
        lastSeen = lastSeen.filter { $0.value.time >= cutoff }
    }

    public func usage(smoothing: TimeInterval, window: TimeInterval, now: Date) -> [String: Usage] {
        let start = now.addingTimeInterval(-window)
        var cpu: [String: Double] = [:], gpu: [String: Double] = [:], gpuSeen: [String: Int] = [:]
        var peak: [String: (cpu: Double, gpu: Double?)] = [:]
        var current: [String: (cpu: Double, gpu: Double?)] = [:]
        var first = 0 // oldest tick inside the smoothing span ending at tick i
        for (i, t) in ticks.enumerated() {
            for (k, u) in t.usage {
                cpu[k, default: 0] += u.cpu
                if let g = u.gpu { gpu[k, default: 0] += g; gpuSeen[k, default: 0] += 1 }
            }
            while ticks[first].time <= t.time.addingTimeInterval(-smoothing) {
                for (k, u) in ticks[first].usage {
                    cpu[k]! -= u.cpu
                    if let g = u.gpu { gpu[k]! -= g; gpuSeen[k]! -= 1 }
                }
                first += 1
            }
            guard t.time > start else { continue }
            let n = Double(i - first + 1)
            current = [:]
            for (k, c) in cpu {
                let s = (cpu: max(c, 0) / n, gpu: (gpuSeen[k] ?? 0) > 0 ? max(gpu[k] ?? 0, 0) / n : nil)
                if s.cpu > 0 || (s.gpu ?? 0) > 0 || t.usage[k] != nil { current[k] = s }
                if let p = peak[k], p.cpu + (p.gpu ?? 0) >= s.cpu + (s.gpu ?? 0) { continue }
                peak[k] = s
            }
        }
        var out: [String: Usage] = [:]
        for (k, p) in peak {
            guard let g = lastSeen[k]?.group else { continue }
            let c = current[k]
            out[k] = Usage(group: g, cpu: c?.cpu ?? 0, gpu: c?.gpu ?? p.gpu.map { _ in 0 }, peakCPU: p.cpu, peakGPU: p.gpu)
        }
        return out
    }
}
