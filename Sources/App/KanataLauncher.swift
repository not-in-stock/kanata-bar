import Foundation
import Shared

enum LauncherEvent {
    case started(pid: Int32)
    case exited(code: Int32)
    case failed
    case error(String)
}

/// Abstraction for the kanata launch/stop mechanism.
/// Implementations: `SudoLauncher` (PAM/TouchID) and `AuthExecLauncher` (password dialog).
@MainActor
protocol KanataLauncher: AnyObject {
    /// Start kanata asynchronously. Must eventually call `onEvent`.
    func start()
    /// Stop kanata (or cancel pending auth dialog).
    func stop()
    /// Force kill and free all resources (called on app quit).
    func cleanup()

    /// Single callback for all launcher events (set by KanataProcess before start).
    var onEvent: ((LauncherEvent) -> Void)? { get set }
}

// MARK: - Shared Utilities

/// A user-owned file the root launcher wrapper polls; deleting it makes the
/// wrapper exit and SIGKILL kanata via its `EXIT` trap. This is how `stop()`
/// works with no second privileged call (no sudo/TouchID/AuthExec re-prompt).
/// Shared by `SudoLauncher` and `AuthExecLauncher` so the path can never drift
/// between the two.
enum StopSentinel {
    static var path: String {
        NSHomeDirectory() + "/Library/Caches/com.kanata-bar/kanata-stop.sentinel"
    }

    /// Create the sentinel (and its directory) before launching the wrapper.
    static func create() {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    /// Delete the sentinel → any running wrapper exits and reaps kanata.
    static func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func killLeftoverKanata() {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    pkill.arguments = ["-n", "/usr/bin/pkill", "-x", Constants.kanataBinaryName]
    pkill.standardInput = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()
}

func isProcessAlive(_ pid: Int32) -> Bool {
    // kill(pid, 0) checks existence without sending a signal.
    // EPERM means the process exists but is owned by another user (e.g. root).
    kill(pid, 0) == 0 || errno == EPERM
}
