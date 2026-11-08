import PaellaCore
import AppKit

if CLI.isCLICommand {
    Task { exit(await CLI.run()) }
    dispatchMain()
}

/// One instance per user, however it is launched (bundle, bare binary, Xcode): an exclusive flock on
/// a file in Application Support. The kernel releases it when the process dies, even on kill -9.
func acquireInstanceLock(waitSeconds: Double) -> Bool {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Paella")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        atgLog("cannot open instance lock; continuing")
        return true
    }
    let deadline = Date().addingTimeInterval(waitSeconds)
    repeat {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true } // fd stays open for the process lifetime
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    close(fd)
    return false
}

// The watchdog's instance waits for the one it replaces to quit.
if !acquireInstanceLock(waitSeconds: LaunchAgent.isLaunchedByAgent ? 10 : 0) {
    atgLog("Paella is already running; exiting")
    exit(0)
}

PaellaApp.main()
