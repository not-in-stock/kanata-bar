import Foundation
import Shared

/// Abstraction for the kanata launch/stop mechanism.
/// Implementations: `SudoLauncher` (PAM/TouchID) and `AuthExecLauncher` (password dialog).
protocol KanataLauncher: AnyObject {
    /// Start kanata asynchronously. Must eventually call one of the callbacks.
    func start()
    /// Stop kanata (or cancel pending auth dialog).
    func stop()
    /// Force kill and free all resources (called on app quit).
    func cleanup()

    // Callbacks (set by KanataProcess before start)
    var onStarted: ((Int32) -> Void)? { get set }   // PID found
    var onExited: ((Int32) -> Void)? { get set }     // exit code
    var onFailure: (() -> Void)? { get set }          // auth denied / binary missing
    var onError: ((String) -> Void)? { get set }      // error message
}

// MARK: - Shared Utilities

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
