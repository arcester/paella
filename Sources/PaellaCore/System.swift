import Foundation

public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

public enum LowPowerMode {
    public static var isEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Uses the sudoers rule installed by PrivilegeHelper; never prompts.
    @discardableResult
    public static func set(_ on: Bool, dryRun: Bool) -> Bool {
        atgLog("\(dryRun ? "[dry-run] " : "")pmset -a lowpowermode \(on ? 1 : 0)")
        if dryRun { return true }
        let ok = Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]) == 0
        if !ok { atgLog("pmset failed (sudoers rule missing?)") }
        return ok
    }
}

/// Installs a least-privilege sudoers rule allowing exactly `pmset -a lowpowermode 0|1`.
public enum PrivilegeHelper {
    public static let sudoersPath = "/etc/sudoers.d/paella"

    public static var isInstalled: Bool {
        // The file check avoids a false positive from a cached sudo timestamp.
        FileManager.default.fileExists(atPath: sudoersPath)
            && Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "lowpowermode", "1"]) == 0
    }

    /// Returns an error message, or nil on success. Shows the system admin-password dialog.
    @MainActor
    public static func install() -> String? {
        // Only an integer uid is interpolated; the username is resolved inside the root shell.
        let script = """
        set -e
        U=$(/usr/bin/id -un \(getuid()))
        T=$(/usr/bin/mktemp /tmp/paella.XXXXXX)
        trap '/bin/rm -f "$T"' EXIT
        /usr/bin/printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1\\n' "$U" > "$T"
        /usr/sbin/visudo -cf "$T"
        /usr/sbin/chown root:wheel "$T"
        /bin/chmod 0440 "$T"
        /bin/mkdir -p /etc/sudoers.d
        /bin/mv -f "$T" \(sudoersPath)
        """
        return runPrivileged(script)
    }

    @MainActor
    public static func uninstall() -> String? {
        runPrivileged("/bin/rm -f \(sudoersPath)")
    }

    @MainActor
    private static func runPrivileged(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
    }
}

/// Optional watchdog: launchd restarts the app if it is killed, and the fresh instance
/// immediately resumes anything listed in state.json.
public enum LaunchAgent {
    public static let label = "com.guzman.Paella.watchdog"
    public static var plistURL: URL { url }
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }
    /// True when this process was started by the watchdog job.
    public static var isLaunchedByAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    public static func install(executable: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Restart only on crash / kill, not after a normal Quit (exit 0).
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if Shell.run("/bin/launchctl", ["bootstrap", domain, url.path]) != 0 {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "falló launchctl bootstrap"])
        }
    }

    public static func uninstall() {
        try? FileManager.default.removeItem(at: url)
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    }
}
