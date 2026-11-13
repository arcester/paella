import PaellaCore
import AppKit

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
    static let autoRefresh = "autoRefreshProcessList" // menu open: refresh the list periodically
    static let refreshInterval = "processListRefreshInterval" // seconds
    static let listMinCPU = "processListMinCPU" // cores
    static let listMinGPU = "processListMinGPU" // share of GPU time
    static let listWindow = "processListAverageWindow" // minutes the list ranking averages over
    static let menuBarPower = "menuBarShowPower" // second line under the menu bar temperature
    static let tempUnit = "temperatureUnit" // "auto" | "c" | "f"
    static let appearance = "appearance" // "system" | "light" | "dark"
    static let menuBarTemp = "menuBarTemperature" // "smoothed" | "max" | "pan"
    static let menuBarIndicator = "menuBarIndicator" // "always" | "alert" (only when not green) | "text" (coloured values)
    static let menuBarWeight = "menuBarFontWeight" // "regular" | "medium" | "semibold" | "bold"
    static let savedLPM = "savedLowPowerMode" // user's LPM state while the last-resort stage is engaged

    static var defaults: [String: Any] { [
        enabled: true, autoRefresh: true, refreshInterval: 10.0, listMinCPU: 0.05, listMinGPU: 0.02, listWindow: 10.0, menuBarTemp: "smoothed", menuBarIndicator: "always", menuBarWeight: "regular", tempUnit: "auto", appearance: "system", menuBarPower: true, target: 82.0, dutyMin: 0.3, leaveFrontmost: true, eCoresFirst: true, lpmFallback: false,
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
    static let refreshInterval = 5.0...60
    // The scan feeds the controller too: these must stay under the lowest cpuThreshold / gpuThreshold
    // (and the 0.2-core known-GPU rule), or demanding processes would go unseen.
    static let listMinCPU = 0.01...0.2
    static let listMinGPU = 0.01...0.05
    static let listWindow = 1.0...30
}

/// Light or dark windows (menu and Settings) regardless of the system, or following it.
@MainActor func applyAppearance() {
    NSApplication.shared.appearance = switch UserDefaults.standard.string(forKey: Key.appearance) {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
}

/// Display unit only: sensors, target and controller all stay in Celsius.
enum TempUnit {
    static var fahrenheit: Bool {
        switch UserDefaults.standard.string(forKey: Key.tempUnit) {
        case "f": true
        case "c": false
        default: Locale.current.measurementSystem == .us
        }
    }
    static var symbol: String { fahrenheit ? "°F" : "°C" }
}

/// An absolute temperature converted to the display unit (charts).
func displayTemp(_ celsius: Double) -> Double { TempUnit.fahrenheit ? celsius * 9 / 5 + 32 : celsius }

/// An absolute temperature for display: "72 °C" / "162 °F".
func temp(_ celsius: Double, _ digits: Int = 0) -> String {
    "\(dec(displayTemp(celsius), digits)) \(TempUnit.symbol)"
}

/// A temperature difference for display: 2 °C → "4 °F" (no +32 offset).
func tempDelta(_ celsius: Double) -> String {
    "\(dec(TempUnit.fahrenheit ? celsius * 9 / 5 : celsius, 0)) \(TempUnit.symbol)"
}

struct Settings {
    var enabled, leaveFrontmost, eCoresFirst, lpmFallback: Bool
    var target, dutyMin, kp, ki, tau, period, cpuThreshold, gpuThreshold, listMinCPU, listMinGPU, listWindow: Double
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
            listMinCPU: clamp(d.double(forKey: Key.listMinCPU), Limits.listMinCPU),
            listMinGPU: clamp(d.double(forKey: Key.listMinGPU), Limits.listMinGPU),
            listWindow: clamp(d.double(forKey: Key.listWindow), Limits.listWindow),
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
