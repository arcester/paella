import Foundation
import Testing
@testable import PaellaCore

private func group(_ path: String, cpu: Double) -> TargetGroup {
    TargetSelector.groups([ProcessSample(key: ProcessKey(pid: 1, start: 1), name: (path as NSString).lastPathComponent,
                                         path: path, cpu: cpu, gpu: nil)])[0]
}

@Test func peaksOfTheSmoothedUseRankSustainedWorkOverSpikes() {
    var avg = UsageAverager(retention: 700)
    let t0 = Date(timeIntervalSince1970: 1000)
    let spike = { group("/Applications/Spike.app/Contents/MacOS/Spike", cpu: $0) }
    let busy = { group("/Applications/Busy.app/Contents/MacOS/Busy", cpu: $0) }
    // Ticks every 2 s. Spike: one 2 s tick at 4 cores. Busy: 20 s at 2 cores, then idle.
    for i in 0..<60 {
        var groups: [TargetGroup] = []
        if i == 5 { groups.append(spike(4)) }
        if (10..<20).contains(i) { groups.append(busy(2)) }
        avg.record(groups, at: t0.addingTimeInterval(Double(i) * 2))
    }
    let now = t0.addingTimeInterval(118)
    let u = avg.usage(smoothing: 10, window: 600, now: now)
    // 10 s = 5 ticks: the spike is diluted to 4 / 5, the sustained load keeps its 2 cores.
    #expect(abs(u[spike(0).key]!.peakCPU - 0.8) < 1e-9)
    #expect(abs(u[busy(0).key]!.peakCPU - 2) < 1e-9)
    #expect(u[busy(0).key]!.peakDemand > u[spike(0).key]!.peakDemand)
    // Both are idle now.
    #expect(u[busy(0).key]!.cpu == 0)
    #expect(u[busy(0).key]!.gpu == nil)
    // A window that starts after the burst no longer sees it.
    #expect((avg.usage(smoothing: 10, window: 30, now: now)[busy(0).key]?.peakCPU ?? 0) == 0)
}
