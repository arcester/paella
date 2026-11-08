import Testing
@testable import PaellaCore

/// Two-node first-order model: a fast die on top of a slow chassis.
/// Full load (20 W) settles at 105 °C die / 85 °C chassis, like a fanless Air.
struct ThermalPlant {
    var chassis = 25.0, die = 25.0
    var loadWatts = 18.0, idleWatts = 2.0
    var lowPowerMode = false
    let ambient = 25.0

    mutating func step(duty: Double, dt: Double) {
        let p = idleWatts + loadWatts * duty * (lowPowerMode ? 0.4 : 1)
        chassis += (ambient + 3 * p - chassis) * dt / 400
        die += (chassis + 1 * p - die) * dt / 5
    }
}

struct Simulation {
    var plant = ThermalPlant()
    var ema = EMA(tau: 60)
    var controller = ThermalController()
    var config = ControllerConfig()
    var lpmRequests: [(time: Double, on: Bool)] = []
    var trace: [(t: Double, smoothed: Double, duty: Double)] = []

    mutating func run(seconds: Double, from start: Double = 0, dt: Double = 2) {
        var t = start
        var duty = controller.duty
        while t < start + seconds {
            plant.step(duty: duty, dt: dt)
            t += dt
            let smoothed = ema.update(plant.die, now: t)
            let out = controller.update(temperature: smoothed, now: t, systemLowPowerMode: plant.lowPowerMode, config: config)
            duty = out.duty
            if let on = out.lowPowerMode { plant.lowPowerMode = on; lpmRequests.append((t, on)) }
            trace.append((t, smoothed, duty))
        }
    }
}

/// 14 W ≈ sustained transcode, 18 W ≈ CPU+GPU flat out (die would reach 105 °C uncontrolled).
@Test(arguments: [14.0, 18.0])
func convergesToTargetWithoutOscillation(load: Double) {
    var sim = Simulation()
    sim.plant.loadWatts = load
    sim.run(seconds: 3600)
    let target = sim.config.target
    guard let firstCross = sim.trace.firstIndex(where: { $0.smoothed >= target }) else {
        Issue.record("never reached target"); return
    }
    let after = sim.trace[firstCross...]
    let maxDev = after.map { abs($0.smoothed - target) }.max()!
    #expect(maxDev <= 2, "deviation after first crossing: \(maxDev)")
    #expect(abs(sim.trace.last!.smoothed - target) < 0.5)
    #expect(sim.trace.last!.duty > 0.3 && sim.trace.last!.duty < 1)
}

@Test func neverBelowDutyMin() {
    var sim = Simulation()
    sim.plant.loadWatts = 60 // cannot reach target even at dutyMin
    sim.run(seconds: 1800)
    #expect(sim.trace.allSatisfy { $0.duty >= sim.config.dutyMin - 1e-12 })
    #expect(sim.trace.last!.duty == sim.config.dutyMin)
}

@Test func lowPowerModeEngagesAndReleases() {
    var sim = Simulation()
    sim.plant.loadWatts = 60
    sim.config.lpmFallback = true
    sim.run(seconds: 1800)
    // Engaged once, after > 3 min pinned at dutyMin while > target + 5.
    #expect(sim.lpmRequests.count == 1 && sim.lpmRequests.first?.on == true)
    #expect(sim.controller.savedLowPowerMode == false)
    let engagedAt = sim.lpmRequests[0].time
    let pinnedSince = sim.trace.first { $0.duty == sim.config.dutyMin && $0.smoothed > sim.config.target + 5 }!.t
    #expect(engagedAt - pinnedSince > 180)

    // Load stops: cools below target − 5 and restores the user's previous state (off) after > 2 min.
    sim.plant.loadWatts = 0
    sim.run(seconds: 3600, from: sim.trace.last!.t)
    #expect(sim.lpmRequests.count == 2 && sim.lpmRequests.last?.on == false)
    #expect(sim.controller.savedLowPowerMode == nil)
    #expect(sim.plant.lowPowerMode == false)
    let coolSince = sim.trace.first { $0.t > engagedAt && $0.smoothed < sim.config.target - 5 }!.t
    #expect(sim.lpmRequests[1].time - coolSince > 120)
}

@Test func previouslyEnabledLowPowerModeIsNeverTouched() {
    var sim = Simulation()
    sim.plant.loadWatts = 150 // hot enough to pin dutyMin even in LPM, so the stage does engage
    sim.plant.lowPowerMode = true // user already runs in LPM
    sim.config.lpmFallback = true
    sim.run(seconds: 1800)
    #expect(sim.controller.savedLowPowerMode == true) // stage engaged, but no change was needed
    sim.plant.loadWatts = 0
    sim.run(seconds: 3600, from: sim.trace.last!.t)
    #expect(sim.lpmRequests.isEmpty)
    #expect(sim.plant.lowPowerMode == true)
}

@Test func releaseOnQuitRestoresPreviousState() {
    var c = ThermalController(savedLowPowerMode: false)
    #expect(c.releaseLowPowerMode(systemLowPowerMode: true) == false)
    #expect(c.releaseLowPowerMode(systemLowPowerMode: true) == nil) // already released
    var d = ThermalController(savedLowPowerMode: true)
    #expect(d.releaseLowPowerMode(systemLowPowerMode: true) == nil)
}

@Test func emaSeedsWithFirstReadingAndTracksStep() {
    var e = EMA(tau: 60)
    #expect(e.update(50, now: 0) == 50)
    let after60 = e.update(100, now: 60)
    #expect(abs(after60 - (50 + 50 * (1 - 1 / 2.718281828))) < 0.01)
}
