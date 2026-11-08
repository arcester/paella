import PaellaCore
import Foundation

enum CLI {
    static let args = CommandLine.arguments

    static func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    static func list(_ flag: String) -> [String]? {
        value(flag)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static var isCLICommand: Bool { args.contains("--dump-sensors") || value("--log-csv") != nil }

    static func run() async -> Int32 {
        let filters = list("--filters") ?? HIDThermalReader.defaultFilters
        let excludes = list("--exclude") ?? HIDThermalReader.defaultExcludes
        let reader = HIDThermalReader()

        if args.contains("--dump-sensors") {
            let readings = await reader.readAll(filters: filters, excludes: excludes)
            print("Filters: \(filters.joined(separator: ", "))   Exclude: \(excludes.joined(separator: ", "))")
            print("Sensors found: \(readings.count)")
            for r in readings {
                print("\(r.matched ? "*" : " ") \(r.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%7.2f", r.celsius)) °C")
            }
            let matched = readings.filter(\.matched)
            print("\nMatched (\(matched.count)): \(matched.map(\.name).joined(separator: ", "))")
            print(HIDThermalReader.dieMax(readings).map { String(format: "dieMax = %.2f °C", $0) } ?? "dieMax = n/a (no valid matched sensor)")
            return 0
        }

        guard let path = value("--log-csv") else { return 2 }
        guard FileManager.default.createFile(atPath: path, contents: nil), let fh = FileHandle(forWritingAtPath: path) else {
            FileHandle.standardError.write(Data("Cannot create \(path)\n".utf8))
            return 1
        }
        let first = await reader.readAll(filters: filters, excludes: excludes)
        // Sensor names repeat on some chips; suffix duplicates so CSV columns stay unique.
        var seen: [String: Int] = [:]
        let columns = first.map { r -> String in
            seen[r.name, default: 0] += 1
            return seen[r.name]! > 1 ? "\(r.name)#\(seen[r.name]!)" : r.name
        }
        fh.write(Data(("timestamp,dieMax," + columns.map { "\"\($0)\"" }.joined(separator: ",") + "\n").utf8))
        print("Logging \(columns.count) sensors every 2 s to \(path) (Ctrl-C to stop)")
        let iso = ISO8601DateFormatter()
        while true {
            let r = await reader.readAll(filters: filters, excludes: excludes)
            let row = [iso.string(from: Date()), HIDThermalReader.dieMax(r).map { String(format: "%.2f", $0) } ?? ""]
                + r.map { String(format: "%.2f", $0.celsius) }
            fh.write(Data((row.joined(separator: ",") + "\n").utf8))
            try? fh.synchronize()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
