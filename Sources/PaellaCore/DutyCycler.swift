import Darwin
import Foundation

public func atgLog(_ message: String) {
    let ts = Date().formatted(.iso8601.time(includingFractionalSeconds: false))
    FileHandle.standardError.write(Data("[\(ts)] \(message)\n".utf8))
}

/// Persisted set of processes we may have stopped or demoted, so a crash never leaves them frozen.
public struct StateStore: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: ProcessKey
        public let demoted: Bool
    }

    public let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Paella/state.json")) {
        self.url = url
    }

    public func save(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            atgLog("state.json write failed: \(error)")
        }
    }

    public func load() -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
}

/// Sends the actual signals / taskpolicy calls. In dry-run mode it only logs.
public struct ProcessControl: Sendable {
    public let dryRun: Bool
    public init(dryRun: Bool) { self.dryRun = dryRun }

    func stop(_ k: ProcessKey) { if !dryRun { kill(k.pid, SIGSTOP) } }
    func resume(_ k: ProcessKey) { if !dryRun { kill(k.pid, SIGCONT) } }

    func setBackground(_ k: ProcessKey, _ on: Bool) {
        atgLog("\(dryRun ? "[dry-run] " : "")taskpolicy \(on ? "-b" : "-B") -p \(k.pid)")
        if !dryRun { Shell.run("/usr/sbin/taskpolicy", [on ? "-b" : "-B", "-p", String(k.pid)]) }
    }
}

/// Duty-cycles the target processes with SIGSTOP/SIGCONT and demotes them to E-cores.
public final class DutyCycler: @unchecked Sendable {
    // @unchecked: every mutable property below is touched only on `queue` (serial), never elsewhere.
    private let queue = DispatchQueue(label: "Paella.DutyCycler", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var timerPeriod = 0.0
    private var targets: Set<ProcessKey> = []
    private var demoted: Set<ProcessKey> = []
    private var duty = 1.0
    private var period = 0.2
    private let control: ProcessControl
    private let store: StateStore

    public init(control: ProcessControl, store: StateStore = StateStore()) {
        self.control = control
        self.store = store
    }

    /// Resumes and un-demotes everything a previous (crashed or killed) instance left behind.
    /// Always for real, even in dry-run: resuming is the safe direction, and the record is cleared after.
    public func recoverFromPreviousRun() {
        let real = ProcessControl(dryRun: false)
        queue.sync {
            for e in store.load() where ProcInfo.isAlive(e.key) {
                atgLog("recovering pid \(e.key.pid) from previous run")
                real.resume(e.key)
                if e.demoted { real.setBackground(e.key, false) }
            }
            store.save([])
        }
    }

    /// Sets the throttled set. Targets not in `demote` (or removed) are restored from E-cores;
    /// removed targets get a final SIGCONT.
    public func apply(targets newTargets: Set<ProcessKey>, demote: Set<ProcessKey>, duty newDuty: Double, period newPeriod: Double) {
        queue.async { [self] in
            let removed = targets.subtracting(newTargets)
            for k in removed {
                atgLog("release pid \(k.pid)")
                control.resume(k)
            }
            for k in newTargets.subtracting(targets) { atgLog("throttle pid \(k.pid)") }
            let wantDemoted = demote.intersection(newTargets)
            for k in demoted.subtracting(wantDemoted) where ProcInfo.isAlive(k) { control.setBackground(k, false) }
            for k in wantDemoted.subtracting(demoted) where ProcInfo.isAlive(k) { control.setBackground(k, true) }
            let changed = targets != newTargets || demoted != wantDemoted
            targets = newTargets
            demoted = wantDemoted
            duty = min(max(newDuty, 0.01), 1)
            period = min(max(newPeriod, 0.05), 2)
            if changed { persist() }
            updateTimer()
        }
    }

    /// Panic / quit path: everything resumed and restored before returning.
    public func resumeAll() {
        queue.sync {
            for k in targets { control.resume(k) }
            for k in demoted where ProcInfo.isAlive(k) { control.setBackground(k, false) }
            if !targets.isEmpty { atgLog("resumed \(targets.count) process(es)") }
            targets = []
            demoted = []
            updateTimer()
            persist()
        }
    }

    private func persist() {
        store.save(targets.map { StateStore.Entry(key: $0, demoted: demoted.contains($0)) })
    }

    private func updateTimer() {
        let needed = !targets.isEmpty && duty < 1
        if needed, timer == nil || timerPeriod != period {
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            timerPeriod = period
        } else if !needed, let t = timer {
            t.cancel()
            timer = nil
            for k in targets { control.resume(k) } // duty back to 1: leave them running
        }
    }

    private func tick() {
        guard duty < 1, !targets.isEmpty else { return }
        for k in targets { control.resume(k) }
        queue.asyncAfter(deadline: .now() + duty * period) { [weak self] in self?.stopPhase() }
    }

    private func stopPhase() {
        guard duty < 1 else { return }
        var gone: [ProcessKey] = []
        for k in targets {
            // Verify identity before every SIGSTOP so a reused PID is never frozen.
            if ProcInfo.isAlive(k) { control.stop(k) } else { gone.append(k) }
        }
        if !gone.isEmpty {
            targets.subtract(gone)
            demoted.subtract(gone)
            persist()
            updateTimer()
        }
    }
}
