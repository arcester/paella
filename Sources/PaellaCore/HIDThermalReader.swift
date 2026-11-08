import CHIDPrivate
import Foundation

public struct SensorReading: Sendable {
    public let name: String
    public let celsius: Double
    public let matched: Bool
}

public struct ThermalSample: Sendable {
    public let dieMax: Double
    public let dieSmoothed: Double
    /// True when no HID sensor was valid and `ProcessInfo.thermalState` was used instead.
    public let usingFallback: Bool
    public let matchedSensors: Int
}

/// Owns the HID event-system client. CF types are not Sendable, so they never leave this actor.
public actor HIDThermalReader {
    public static let defaultFilters = ["tdie", "pACC", "eACC", "SOC", "GPU", "PMU"]
    /// `tcal` is a fixed calibration constant (~51.8 °C), not a live temperature.
    public static let defaultExcludes = ["tcal"]
    public static let validRange = 10.0...130.0

    private let client: ATGHIDEventSystemClient?
    private var services: [(name: String, ref: ATGHIDServiceClient)] = []
    private var ema = EMA(tau: 60)

    public init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        guard let client else { return }
        // Apple-vendor page 0xFF00, usage 5 = temperature sensors.
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 0x0005] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        let array = (IOHIDEventSystemClientCopyServices(client) as? [AnyObject]) ?? []
        services = array.map { obj in
            let svc = unsafeDowncast(obj, to: ATGHIDServiceClient.self)
            return (IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String ?? "?", svc)
        }.sorted { $0.0 < $1.0 }.map { (name: $0.0, ref: $0.1) }
    }

    public static func matches(_ name: String, filters: [String], excludes: [String]) -> Bool {
        let has = { (f: String) in !f.isEmpty && name.range(of: f, options: .caseInsensitive) != nil }
        return filters.contains(where: has) && !excludes.contains(where: has)
    }

    /// Reads every sensor; `celsius` is NaN when the service returned no event.
    public func readAll(filters: [String] = defaultFilters, excludes: [String] = defaultExcludes) -> [SensorReading] {
        services.map { svc in
            // 15 = kIOHIDEventTypeTemperature; field = type << 16.
            let value = IOHIDServiceClientCopyEvent(svc.ref, 15, 0, 0).map { IOHIDEventGetFloatValue($0, 15 << 16) } ?? .nan
            return SensorReading(name: svc.name, celsius: value, matched: Self.matches(svc.name, filters: filters, excludes: excludes))
        }
    }

    /// Max valid reading among matched sensors, nil if none is valid.
    public static func dieMax(_ readings: [SensorReading]) -> Double? {
        readings.filter { $0.matched && validRange.contains($0.celsius) }.map(\.celsius).max()
    }

    /// One control-loop sample: dieMax plus its EMA (time constant `tau` seconds).
    public func sample(now: Double, tau: Double, filters: [String], excludes: [String]) -> ThermalSample {
        let readings = readAll(filters: filters, excludes: excludes)
        let matched = readings.filter { $0.matched && Self.validRange.contains($0.celsius) }.count
        ema.tau = tau
        if let m = Self.dieMax(readings) {
            return ThermalSample(dieMax: m, dieSmoothed: ema.update(m, now: now), usingFallback: false, matchedSensors: matched)
        }
        let pseudo: Double = switch ProcessInfo.processInfo.thermalState {
        case .nominal: 50
        case .fair: 75
        case .serious: 90
        case .critical: 100
        @unknown default: 90
        }
        return ThermalSample(dieMax: pseudo, dieSmoothed: ema.update(pseudo, now: now), usingFallback: true, matchedSensors: 0)
    }
}
