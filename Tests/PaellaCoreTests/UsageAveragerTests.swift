import Foundation
import Testing
@testable import PaellaCore

private func group(_ path: String, cpu: Double) -> TargetGroup {
    TargetSelector.groups([ProcessSample(key: ProcessKey(pid: 1, start: 1), name: (path as NSString).lastPathComponent,
                                         path: path, cpu: cpu, gpu: nil)])[0]
}

@Test func averagesCountAbsentTicksAsZeroAndForgetOldOnes() {
    var avg = UsageAverager(retention: 60)
    let t0 = Date(timeIntervalSince1970: 1000)
    let burst = group("/Applications/Burst.app/Contents/MacOS/Burst", cpu: 4)
    let steady = group("/Applications/Steady.app/Contents/MacOS/Steady", cpu: 1)
    // A 2 s burst of 4 cores, then 3 ticks without it; Steady uses 1 core all along.
    avg.record([burst, steady], at: t0)
    for i in 1...3 { avg.record([steady], at: t0.addingTimeInterval(Double(i) * 2)) }
    let now = t0.addingTimeInterval(6)
    let a = avg.averages(window: 60, now: now)
    #expect(a[burst.key]?.cpu == 1) // 4 / 4 ticks
    #expect(a[steady.key]?.cpu == 1)
    #expect(a[burst.key]?.gpu == nil)
    // A shorter window no longer sees the burst.
    #expect(avg.averages(window: 5, now: now)[burst.key] == nil)
    // Past retention, the burst is dropped entirely.
    avg.record([steady], at: t0.addingTimeInterval(120))
    #expect(avg.averages(window: 600, now: t0.addingTimeInterval(120))[burst.key] == nil)
}
