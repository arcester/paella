import PaellaCore
import AppKit
import Observation
import ServiceManagement

enum ProcessState {
    case limited     // being slowed down right now
    case unlimited   // the user marked it "Ilimitado": never limited
    case foreground  // frontmost app, left alone
    case system      // system component, never touched
    case normal      // not limited at the moment
}

struct MonitoredGroup: Identifiable {
    let group: TargetGroup
    var state: ProcessState
    /// False when a row kept by the frozen list no longer shows up in the latest scan.
    var active = true
    var id: String { group.key }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let dieMax: Double
    let smoothed: Double
}

@MainActor @Observable
final class AppModel {
    let dryRun: Bool
    private(set) var sample: ThermalSample?
    private(set) var history: [HistoryPoint] = []
    private(set) var targets: [TargetGroup] = []
    /// The most demanding processes (grouped by app), with their state.
    private(set) var monitored: [MonitoredGroup] = []
    /// While the menu is open the list keeps the same rows (no automatic entries or exits).
    var menuVisible = false {
        didSet {
            guard menuVisible != oldValue else { return }
            atgLog(menuVisible ? "menu opened: process list frozen" : "menu closed: process list live")
            frozenKeys = menuVisible ? monitored.map(\.id) : nil
            if !menuVisible { recomputeMonitored() }
        }
    }
    private var frozenKeys: [String]?
    private var lastScan: (groups: [TargetGroup], settings: Settings, frontmost: String?)?
    private(set) var throttling = false
    private(set) var duty = 1.0
    private(set) var gpuAvailable = true
    private(set) var sudoersInstalled = PrivilegeHelper.isInstalled
    private(set) var watchdogInstalled = LaunchAgent.isInstalled
    var message: String?
    var settingsTab = "general" // "Ajustes…" resets it so the window never reopens on the last tab used

    private var controller: ThermalController
    private let reader = HIDThermalReader()
    private let monitor = ProcessMonitor()
    private let cycler: DutyCycler
    private var activeGroups: Set<String> = []
    private var signalSources: [DispatchSourceSignal] = []
    private var loop: Task<Void, Never>?
    private var shutDown = false

    var lowPowerModeEngaged: Bool { controller.savedLowPowerMode != nil }

    var menuLabel: String {
        guard let s = sample else { return "–°" }
        let mode = UserDefaults.standard.string(forKey: Key.menuBarTemp)
        let t = mode == "max" ? s.dieMax : s.dieSmoothed
        var label = mode == "pan" ? "" : "\(Int(t.rounded()))°" // "pan": the icon stands in for the number
        if lowPowerModeEngaged && LowPowerMode.isEnabled { label += " " + String(localized: "Ahorro") } else if throttling && duty < 1 { label += " ▼\(Int((duty * 100).rounded()))%" }
        if s.usingFallback { label += " ⚠︎" }
        return label
    }

    init(dryRun: Bool) {
        self.dryRun = dryRun
        UserDefaults.standard.register(defaults: Key.defaults)
        cycler = DutyCycler(control: ProcessControl(dryRun: dryRun))
        // Crash recovery: resume processes and LPM a previous instance left behind.
        cycler.recoverFromPreviousRun()
        let saved = UserDefaults.standard.object(forKey: Key.savedLPM) as? Bool
        controller = ThermalController()
        if let saved, saved != LowPowerMode.isEnabled {
            atgLog("restoring Low Power Mode to \(saved) after previous run")
            LowPowerMode.set(saved, dryRun: false) // restoring the user's own state is always safe
        }
        UserDefaults.standard.removeObject(forKey: Key.savedLPM)
        installTerminationHandlers()
        atgLog("Paella started\(dryRun ? " in DRY-RUN mode (no signals, taskpolicy or pmset)" : "")")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Control loop

    private func tick() async {
        let s = Settings.current()
        let now = Date().timeIntervalSince1970
        let sample = await reader.sample(now: now, tau: s.tau, filters: s.sensorFilters, excludes: s.sensorExcludes)
        let scan = await monitor.scan(keep: Set(targets.flatMap { $0.members.map(\.key) }))
        guard !shutDown else { return }
        self.sample = sample
        gpuAvailable = scan.gpuAvailable
        history.append(HistoryPoint(time: Date(), dieMax: sample.dieMax, smoothed: sample.dieSmoothed))
        if history.count > 300 { history.removeFirst(history.count - 300) } // 10 min at 2 s

        let groups = TargetSelector.groups(scan.samples)
        let front = s.leaveFrontmost ? NSWorkspace.shared.frontmostApplication?.bundleURL?.path : nil
        defer { updateMonitored(groups, settings: s, frontmost: front) }

        guard s.enabled else {
            if throttling || controller.savedLowPowerMode != nil { atgLog("automatic control off: releasing") }
            stopThrottling()
            controller.reset()
            targets = []
            return
        }

        let output = controller.update(temperature: sample.dieSmoothed, now: now,
                                       systemLowPowerMode: LowPowerMode.isEnabled, config: s.controllerConfig)
        if let lpm = output.lowPowerMode { LowPowerMode.set(lpm, dryRun: dryRun) }
        persistSavedLPM()

        var policy = SelectionPolicy()
        policy.cpuThreshold = s.cpuThreshold
        policy.gpuThreshold = s.gpuThreshold
        policy.exclusions = s.exclusions
        policy.knownGPUProcesses = s.knownGPU
        policy.gpuAvailable = scan.gpuAvailable
        policy.activeGroups = activeGroups
        policy.excludedBundlePaths = [Bundle.main.bundlePath] + (front.map { [$0] } ?? [])
        targets = TargetSelector.select(groups, policy: policy)

        // Stage 1 (E-cores) starts 2 °C below target; duty-cycling starts when the PI asks for < 100 %.
        let warm = sample.dieSmoothed > s.target - 2
        let cool = sample.dieSmoothed < s.target - 3
        throttling = output.duty < 1 || (s.eCoresFirst && (warm || (throttling && !cool)))
        duty = output.duty
        let keys = throttling ? Set(targets.flatMap { $0.members.map(\.key) }) : []
        activeGroups = throttling ? Set(targets.map(\.key)) : []
        cycler.apply(targets: keys, demote: s.eCoresFirst ? keys : [], duty: duty, period: s.period)
        if throttling, !targets.isEmpty {
            atgLog(String(format: "die %.1f smoothed %.1f target %.0f duty %.0f%% → %@", sample.dieMax, sample.dieSmoothed, s.target,
                          duty * 100, targets.map { String(format: "%@ (%.0f%% CPU)", $0.name, $0.cpu * 100) }.joined(separator: ", ")))
        }
    }

    private func updateMonitored(_ groups: [TargetGroup], settings s: Settings, frontmost: String?) {
        lastScan = (groups, s, frontmost)
        recomputeMonitored()
    }

    private func recomputeMonitored() {
        guard let scan = lastScan else { return }
        func state(_ g: TargetGroup) -> ProcessState {
            if g.isProtected { return .system }
            if TargetSelector.isExcluded(g, by: scan.settings.exclusions) { return .unlimited }
            if activeGroups.contains(g.key) { return .limited }
            if g.key == scan.frontmost { return .foreground }
            return .normal
        }
        // An empty frozen list (menu opened before the first scan) may fill once, then stays frozen.
        guard let keys = frozenKeys, !keys.isEmpty else {
            monitored = scan.groups.filter { $0.key != Bundle.main.bundlePath }.prefix(6)
                .map { MonitoredGroup(group: $0, state: state($0)) }
            if frozenKeys != nil { frozenKeys = monitored.map(\.id) }
            return
        }
        // Frozen: same rows, fresh numbers; a row missing from the scan keeps its last data.
        let current = Dictionary(scan.groups.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let previous = Dictionary(monitored.map { ($0.id, $0.group) }, uniquingKeysWith: { a, _ in a })
        monitored = keys.compactMap { k in
            if let g = current[k] { return MonitoredGroup(group: g, state: state(g)) }
            return previous[k].map { MonitoredGroup(group: $0, state: state($0), active: false) }
        }
    }

    /// Refresh button: take the current most demanding processes, then keep them while the menu stays open.
    func refreshProcessList() {
        frozenKeys = nil
        recomputeMonitored()
        if menuVisible { frozenKeys = monitored.map(\.id) }
    }

    private func persistSavedLPM() {
        if let saved = controller.savedLowPowerMode {
            UserDefaults.standard.set(saved, forKey: Key.savedLPM)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.savedLPM)
        }
    }

    private func stopThrottling() {
        cycler.resumeAll()
        throttling = false
        duty = 1
        activeGroups = []
        if let restore = controller.releaseLowPowerMode(systemLowPowerMode: LowPowerMode.isEnabled) {
            LowPowerMode.set(restore, dryRun: dryRun)
        }
        persistSavedLPM()
    }

    // MARK: Actions

    /// Turning automatic control off: remove every limit now.
    func resumeAll() {
        UserDefaults.standard.set(false, forKey: Key.enabled)
        stopThrottling()
        controller.reset()
        targets = []
        for i in monitored.indices where monitored[i].state == .limited { monitored[i].state = .normal }
        message = String(localized: "Límites quitados. El control automático está desactivado.")
    }

    /// "Ilimitado": remembered by name in the exclusions setting, so it also applies next time.
    func setUnlimited(_ group: TargetGroup, _ unlimited: Bool) {
        let s = Settings.current()
        var list = s.exclusions.filter { name in
            name.caseInsensitiveCompare(group.name) != .orderedSame
                && !group.members.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        if unlimited { list.append(group.name) }
        UserDefaults.standard.set(list.joined(separator: ", "), forKey: Key.exclusions)
        if let i = monitored.firstIndex(where: { $0.group.key == group.key }) {
            monitored[i].state = unlimited ? .unlimited : .normal
        }
        guard unlimited, activeGroups.contains(group.key) else { return }
        targets.removeAll { $0.key == group.key }
        activeGroups.remove(group.key)
        let remaining = Set(targets.flatMap { $0.members.map(\.key) })
        cycler.apply(targets: throttling ? remaining : [], demote: s.eCoresFirst && throttling ? remaining : [],
                     duty: duty, period: s.period)
    }

    func installSudoers() {
        message = PrivilegeHelper.install().map { String(localized: "Error al instalar: \($0)") }
        sudoersInstalled = PrivilegeHelper.isInstalled
    }

    func removeSudoers() {
        message = PrivilegeHelper.uninstall().map { String(localized: "Error al quitar: \($0)") }
        sudoersInstalled = PrivilegeHelper.isInstalled
        if !sudoersInstalled { UserDefaults.standard.set(false, forKey: Key.lpmFallback) }
    }

    func setWatchdog(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath, Bundle.main.bundlePath.hasSuffix(".app") else {
                message = String(localized: "El vigilante necesita la app empaquetada (scripts/bundle.sh).")
                return
            }
            do {
                try LaunchAgent.install(executable: exe)
                // launchd now starts its own instance; hand over to it.
                if !LaunchAgent.isLaunchedByAgent { NSApp.terminate(nil) }
            } catch {
                message = String(localized: "Error al instalar el vigilante: \(error.localizedDescription)")
            }
        } else {
            // Booting out our own job would SIGTERM us; just remove the plist then (it is gone at next login).
            if LaunchAgent.isLaunchedByAgent { try? FileManager.default.removeItem(at: LaunchAgent.plistURL) } else { LaunchAgent.uninstall() }
        }
        watchdogInstalled = LaunchAgent.isInstalled
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = String(localized: "Abrir al iniciar sesión: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Shutdown

    /// Quit, SIGTERM, SIGINT: resume everything and restore LPM.
    func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        loop?.cancel()
        stopThrottling()
        atgLog("shutdown: all processes resumed")
    }

    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutdown() }
                exit(128 + sig) // non-zero so the watchdog agent (if any) relaunches us
            }
            src.resume()
            signalSources.append(src)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }
}
