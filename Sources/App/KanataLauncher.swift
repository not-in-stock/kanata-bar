import Foundation

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
    pkill.arguments = ["-n", "/usr/bin/pkill", "-x", "kanata"]
    pkill.standardInput = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()
}

func isProcessAlive(_ pid: Int32) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-p", "\(pid)"]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
