import Darwin
import Foundation
import Shared

// kanata-bar-supervise — the privileged, no-args kanata supervisor (task 18 / 2b).
//
// Invoked as `sudo /…/kanata-bar-supervise` and pinned by a sudo `sha256:` digest
// rule with no args, so a passwordless `sudoers` grant can't be repurposed to run
// anything else as root. It takes NO arguments; everything it needs it resolves
// itself:
//   • what to run  ← the root-owned spec /etc/kanata-bar/supervise.env (the
//     privilege boundary — only root writes it).
//   • which user   ← $SUDO_UID, to derive that user's stop-sentinel path.
//   • which app    ← its grandparent pid (the app is the parent of our parent
//     `sudo`), watched so kanata is reaped if the app crashes or quits.
// It launches kanata, prints its pid (so the app's SudoLauncher can read it back,
// exactly like the old shell wrapper), then polls until kanata exits, the app
// dies, or the stop sentinel is deleted — on any of those it SIGKILLs kanata.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kanata-bar-supervise: \(message)\n".utf8))
    exit(1)
}

/// Current kanata child pid, for the signal handlers to kill on a forced exit.
/// A global accessed from an async-signal context — only `kill`/`_exit` run there,
/// both async-signal-safe, and a `pid_t` write is atomic. `nonisolated(unsafe)`
/// because top-level globals are MainActor-isolated but the C handler is not.
nonisolated(unsafe) private var gChildPID: pid_t = -1

private func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { _ in
        if gChildPID > 0 { kill(gChildPID, SIGKILL) }
        _exit(0)
    }
    signal(SIGTERM, handler)
    signal(SIGINT, handler)
    signal(SIGHUP, handler)
}

/// The ppid of `pid`, via sysctl. Used to find the app (our grandparent).
private func parentPID(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard rc == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

// 1. Read the root-owned spec (what to run). Missing → nix hasn't set us up.
guard let specContents = try? String(contentsOfFile: Constants.superviseSpecPath, encoding: .utf8) else {
    fail("cannot read spec \(Constants.superviseSpecPath)")
}
let spec: SuperviseSpec
do {
    spec = try SuperviseSpec.parse(specContents)
} catch {
    fail("invalid spec \(Constants.superviseSpecPath): \(error)")
}
// Defense in depth: the root-owned spec is the real boundary, but still refuse to
// launch anything not named `kanata` (mirrors the XPC helper's basename guard).
guard (spec.kanataBin as NSString).lastPathComponent == Constants.kanataBinaryName else {
    fail("refusing to launch non-kanata binary \(spec.kanataBin)")
}

// 2. Derive the invoking user's stop-sentinel path from $SUDO_UID (we run as root,
//    so NSHomeDirectory would be /var/root). The sentinel only governs *when* to
//    stop, never *what* to run, so a user-owned path here is not an escalation.
guard let uidStr = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = uid_t(uidStr) else {
    fail("SUDO_UID not set — must be run via sudo")
}
guard let pw = getpwuid(uid) else { fail("no passwd entry for uid \(uid)") }
let sentinelPath = Constants.stopSentinelPath(home: String(cString: pw.pointee.pw_dir))

// 3. The app is our grandparent (app → sudo → us). Capture it once so we can reap
//    kanata if the app goes away. `sudo` gets reparented on app death rather than
//    killed, so we watch the app pid directly, not `getppid()`.
guard let sudoPID = parentPID(of: getpid()), let appPID = parentPID(of: sudoPID), appPID > 1 else {
    fail("cannot resolve app pid (grandparent)")
}

// 4. Launch kanata.
installSignalHandlers()

let logHandle: FileHandle?
if let logPath = spec.logPath {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    logHandle = FileHandle(forWritingAtPath: logPath)
} else {
    logHandle = nil
}

let process = Process()
process.executableURL = URL(fileURLWithPath: spec.kanataBin)
process.arguments = spec.kanataArguments()
process.standardInput = FileHandle.nullDevice
process.standardOutput = logHandle ?? FileHandle.nullDevice
process.standardError = logHandle ?? FileHandle.nullDevice

do {
    try process.run()
} catch {
    fail("launch failed: \(error.localizedDescription)")
}

let childPID = process.processIdentifier
gChildPID = childPID

// Report kanata's pid on stdout (first line) — the app's SudoLauncher.readPID
// parses exactly this, unchanged from the shell-wrapper contract.
FileHandle.standardOutput.write(Data("\(childPID)\n".utf8))

// 5. Poll: stay up while kanata is alive AND the app is alive AND the sentinel
//    exists. `isRunning` lets Foundation reap the child (so no zombie fools us).
//    `kill(appPID, 0)` returns EPERM for the user-owned app (we're root) — still
//    "alive". 200ms caps the lag between a trigger and kanata dying.
let fm = FileManager.default
while process.isRunning {
    if kill(appPID, 0) != 0 && errno != EPERM { break }
    if !fm.fileExists(atPath: sentinelPath) { break }
    usleep(200_000)
}

if process.isRunning {
    kill(childPID, SIGKILL)
}
exit(0)
