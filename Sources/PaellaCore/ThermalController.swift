import Foundation

/// Exponential moving average with a time constant, robust to irregular sampling.
public struct EMA: Sendable {
    public var tau: Double
    public private(set) var value: Double?
    private var lastTime: Double?

    public init(tau: Double) { self.tau = tau }

    public mutating func update(_ x: Double, now: Double) -> Double {
        guard let v = value, let t = lastTime else {
            value = x; lastTime = now; return x // seed with the first reading, not 0
        }
        let alpha = 1 - exp(-max(now - t, 0) / max(tau, 0.001))
        let next = v + alpha * (x - v)
        value = next; lastTime = now
        return next
    }
}

public struct ControllerConfig: Sendable, Equatable {
    public var target: Double = 82
    public var dutyMin: Double = 0.3
    /// Duty lost per °C of error: +5 °C → duty 0.5 immediately. A weaker Kp leaves the work to the
    /// integral, which overshoots on the slow chassis (see ThermalControllerTests).
    public var kp: Double = 0.1
    /// Duty lost per °C·s of integrated error: +5 °C for 1 min → another 15 %.
    public var ki: Double = 0.0005
    public var lpmFallback: Bool = false
    public var lpmEngageAfter: Double = 180
    public var lpmReleaseAfter: Double = 120
    public var lpmMargin: Double = 5

    public init() {}
}

public struct ControllerOutput: Sendable, Equatable {
    public var duty: Double
    /// System Low Power Mode state to apply now; nil = leave it alone.
    public var lowPowerMode: Bool?
}

/// Pure PI thermostat. Temperature and clock are injected; no I/O.
public struct ThermalController: Sendable {
    public private(set) var integral = 0.0
    public private(set) var duty = 1.0
    /// User's LPM state captured when the last-resort stage engaged; non-nil while engaged.
    public private(set) var savedLowPowerMode: Bool?
    private var lastTime: Double?
    private var atMinSince: Double?
    private var coolSince: Double?

    public init(savedLowPowerMode: Bool? = nil) { self.savedLowPowerMode = savedLowPowerMode }

    public mutating func update(temperature t: Double, now: Double, systemLowPowerMode: Bool, config c: ControllerConfig) -> ControllerOutput {
        let dt = lastTime.map { min(max(now - $0, 0), 10) } ?? 0 // cap so sleep/wake gaps don't dump into the integral
        lastTime = now
        let error = t - c.target
        let pd = 1 - c.kp * error
        // Anti-windup: stop integrating once the output is pinned at dutyMin and still too hot.
        let pinnedLow = pd - c.ki * integral <= c.dutyMin && error > 0
        if !pinnedLow { integral = max(0, integral + error * dt) } // ≥ 0: time spent cool must not delay the next response
        duty = min(1, max(c.dutyMin, pd - c.ki * integral))

        var lpm: Bool?
        if savedLowPowerMode == nil {
            coolSince = nil
            if c.lpmFallback, duty <= c.dutyMin + 1e-9, t > c.target + c.lpmMargin {
                let since = atMinSince ?? now
                atMinSince = since
                if now - since > c.lpmEngageAfter {
                    savedLowPowerMode = systemLowPowerMode
                    atMinSince = nil
                    if !systemLowPowerMode { lpm = true }
                }
            } else {
                atMinSince = nil
            }
        } else {
            if t < c.target - c.lpmMargin {
                let since = coolSince ?? now
                coolSince = since
                if now - since > c.lpmReleaseAfter { lpm = releaseLowPowerMode(systemLowPowerMode: systemLowPowerMode) }
            } else {
                coolSince = nil
            }
            if !c.lpmFallback { lpm = releaseLowPowerMode(systemLowPowerMode: systemLowPowerMode) }
        }
        return ControllerOutput(duty: duty, lowPowerMode: lpm)
    }

    /// Ends the last-resort stage. Returns the user's previous state if it must be restored.
    public mutating func releaseLowPowerMode(systemLowPowerMode: Bool) -> Bool? {
        guard let saved = savedLowPowerMode else { return nil }
        savedLowPowerMode = nil
        coolSince = nil
        return saved == systemLowPowerMode ? nil : saved
    }

    /// Forget the integral and timing (e.g. when automatic control is turned off). LPM state is kept.
    public mutating func reset() {
        integral = 0; duty = 1; lastTime = nil; atMinSince = nil
    }
}
