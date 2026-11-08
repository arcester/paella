import PaellaCore
import Foundation

/// UserDefaults keys and defaults; views bind the same keys with @AppStorage.
enum Key {
    static let enabled = "enabled"
    static let target = "targetTemperature"
    static let dutyMin = "dutyMin"
    static let leaveFrontmost = "leaveFrontmostAlone"
    static let eCoresFirst = "eCoresFirst"
    static let lpmFallback = "lowPowerModeFallback"
    static let exclusions = "exclusions"
    static let knownGPU = "knownGPUProcesses"
    static let kp = "kp"
    static let ki = "ki"
    static let tau = "smoothingTau"
    static let period = "dutyPeriod"
    static let cpuThreshold = "cpuThreshold"
    static let gpuThreshold = "gpuThreshold"
    static let sensorFilters = "sensorFilters"
    static let sensorExcludes = "sensorExcludes"
    static let menuBarTemp = "menuBarTemperature" // "smoothed" | "max" | "pan"
    static let savedLPM = "savedLowPowerMode" // user's LPM state while the last-resort stage is engaged

    static var defaults: [String: Any] { [
        enabled: true, menuBarTemp: "smoothed", target: 82.0, dutyMin: 0.3, leaveFrontmost: true, eCoresFirst: true, lpmFallback: false,
        exclusions: "", knownGPU: "ollama, LM Studio, python, python3, ffmpeg, HandBrakeCLI",
        kp: ControllerConfig().kp, ki: ControllerConfig().ki, tau: 60.0, period: 0.2,
        cpuThreshold: 0.8, gpuThreshold: 0.2,
        sensorFilters: HIDThermalReader.defaultFilters.joined(separator: ", "),
        sensorExcludes: HIDThermalReader.defaultExcludes.joined(separator: ", "),
    ] }
}

/// Safe ranges for the advanced settings: the sliders offer only these, and reads are clamped to them
/// too, so a hand-edited default (`defaults write`) can't stall the controller or flood signals either.
enum Limits {
    static let kp = 0.02...0.3
    static let ki = 0.0...0.002
    static let tau = 10.0...180
    static let period = 0.1...1
    static let cpuThreshold = 0.3...4
    static let gpuThreshold = 0.05...1
}

struct Settings {
    var enabled, leaveFrontmost, eCoresFirst, lpmFallback: Bool
    var target, dutyMin, kp, ki, tau, period, cpuThreshold, gpuThreshold: Double
    var exclusions, knownGPU, sensorFilters, sensorExcludes: [String]

    static func current(_ d: UserDefaults = .standard) -> Settings {
        func list(_ k: String) -> [String] {
            (d.string(forKey: k) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return Settings(
            enabled: d.bool(forKey: Key.enabled), leaveFrontmost: d.bool(forKey: Key.leaveFrontmost),
            eCoresFirst: d.bool(forKey: Key.eCoresFirst), lpmFallback: d.bool(forKey: Key.lpmFallback),
            target: d.double(forKey: Key.target), dutyMin: min(max(d.double(forKey: Key.dutyMin), 0.1), 1),
            kp: clamp(d.double(forKey: Key.kp), Limits.kp), ki: clamp(d.double(forKey: Key.ki), Limits.ki),
            tau: clamp(d.double(forKey: Key.tau), Limits.tau), period: clamp(d.double(forKey: Key.period), Limits.period),
            cpuThreshold: clamp(d.double(forKey: Key.cpuThreshold), Limits.cpuThreshold),
            gpuThreshold: clamp(d.double(forKey: Key.gpuThreshold), Limits.gpuThreshold),
            exclusions: list(Key.exclusions), knownGPU: list(Key.knownGPU),
            sensorFilters: list(Key.sensorFilters), sensorExcludes: list(Key.sensorExcludes))
    }

    var controllerConfig: ControllerConfig {
        var c = ControllerConfig()
        c.target = target; c.dutyMin = dutyMin; c.kp = kp; c.ki = ki; c.lpmFallback = lpmFallback
        return c
    }
}

func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
