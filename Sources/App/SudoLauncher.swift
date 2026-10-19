import Foundation

/// Launches kanata via `sudo -S` with PAM/TouchID support.
///
/// Stop is **privilege-free**. The root wrapper shell polls a user-owned *stop
/// sentinel* file and exits when it disappears, running its `EXIT` trap to
/// SIGKILL kanata. So `stop()` just deletes the sentinel — no second privileged
/// call, and no dependency on the XPC helper or a passwordless-`sudoers` rule,
/// both of which can be unavailable (the helper doesn't launch on a full-SIP
/// machine without proper signing; `services.kanata.sudoers` may be off). The
/// same wrapper also polls the app's pid, so kanata is reaped if the app crashes
/// or quits. kanata's own exit is tracked app-side via `DispatchSourceProcess`.
@MainActor
class SudoLauncher: KanataLauncher {
    nonisolated let binaryPath: String
    nonisolated let configPath: String
    nonisolated let port: UInt16
    nonisolated let extraArgs: [String]
    nonisolated let logURL: URL?

    private var sudoProcess: Process?
    private var discoveredPID: Int32 = -1
    private var stoppedByUser = false
    private var isStarting = false
    private var processSource: DispatchSourceProcess?

    var onEvent: ((LauncherEvent) -> Void)?

    init(binaryPath: String, configPath: String, port: UInt16, extraArgs: [String], logURL: URL?) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.logURL = logURL
    }

    // MARK: - Start

    func start() {
        // Re-entrancy guard: a second start() would race the in-flight detached
        // task and leave one of two sudo wrappers untracked.
        guard !isStarting else { return }
        isStarting = true
        stoppedByUser = false

        let binaryPath = binaryPath
        let configPath = configPath
        let port = port
        let extraArgs = extraArgs
        let logURL = logURL

        Task.detached { [weak self] in
            killLeftoverKanata()

            let kanataArgs = ([binaryPath, "-c", configPath, "--port", "\(port)"] + extraArgs)
                .map(AuthExecLauncher.shellEscape)
                .joined(separator: " ")
            let logRedirect: String
            if let logURL {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                logRedirect = " > \(AuthExecLauncher.shellEscape(logURL.path)) 2>&1"
            } else {
                logRedirect = ""
            }

            // Create the stop sentinel the wrapper polls (see StopSentinel) so Stop
            // can reap kanata by deleting it — no second sudo call.
            StopSentinel.create()

            // The wrapper reports kanata's pid, then self-cleans: its EXIT trap
            // SIGKILLs kanata whenever it exits, and the poll loop ends when kanata
            // dies, the app dies (crash/quit), or the stop sentinel is deleted
            // (explicit Stop). Shared verbatim with AuthExecLauncher.
            let appPID = ProcessInfo.processInfo.processIdentifier
            let script = AuthExecLauncher.makeWrapperScript(
                kanataCommand: "\(kanataArgs)\(logRedirect)", appPID: appPID, sentinelPath: StopSentinel.path)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-S", "/bin/sh", "-c", script]

            let stdinPipe = Pipe()
            stdinPipe.fileHandleForWriting.closeFile()
            p.standardInput = stdinPipe
            let stdoutPipe = Pipe()
            p.standardOutput = stdoutPipe
            p.standardError = FileHandle.nullDevice

            p.terminationHandler = { [weak self] proc in
                let exitCode = proc.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let pidWasDiscovered = self.discoveredPID > 0
                    let wasStopped = self.stoppedByUser
                    self.sudoProcess = nil
                    // Once kanata's pid is known its exit is owned by the process
                    // monitor, and this wrapper now only exits when the app is going
                    // away or on an explicit Stop — don't surface that as a kanata
                    // event. Only report a pre-pid failure (auth denied / never ran).
                    guard !pidWasDiscovered else { return }
                    self.stoppedByUser = false
                    if !wasStopped && exitCode != 0 {
                        self.finishStart(.failed)
                    } else {
                        self.isStarting = false
                    }
                }
            }

            do {
                try p.run()
                await MainActor.run { [weak self] in
                    self?.sudoProcess = p
                }

                guard let pid = Self.readPID(from: stdoutPipe.fileHandleForReading),
                      !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.discoveredPID = pid
                    self.finishStart(.started(pid: pid))
                    self.startProcessMonitor(pid: pid)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.finishStart(.error("failed to start kanata: \(message)"))
                }
            }
        }
    }

    /// Terminal point of every start() path: clears the re-entrancy flag, then
    /// reports the outcome.
    private func finishStart(_ event: LauncherEvent) {
        isStarting = false
        onEvent?(event)
    }

    // MARK: - Stop

    func stop() {
        stoppedByUser = true
        // Delete the sentinel → the root wrapper's poll loop exits → its EXIT trap
        // SIGKILLs kanata. Privilege-free; needs neither the helper nor sudoers.
        StopSentinel.remove()
        // If kanata hasn't started yet we're still at the sudo auth prompt — cancel
        // it by terminating sudo (no backgrounded kanata to orphan yet).
        if discoveredPID <= 0, let proc = sudoProcess, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Process Monitor

    /// Detect kanata's own exit (crash, explicit Stop, or app teardown) client-side,
    /// the same way `AuthExecLauncher` does — the wrapper no longer `wait`s on kanata.
    private func startProcessMonitor(pid: Int32) {
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.processSource = nil
            self.discoveredPID = -1
            self.onEvent?(.exited(code: 1))
        }
        source.resume()
        processSource = source

        // Safety net: if kanata exited before kevent registration, the handler
        // never fires. Detect it immediately.
        if !isProcessAlive(pid) {
            processSource?.cancel()
            processSource = nil
            discoveredPID = -1
            onEvent?(.exited(code: 1))
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        processSource?.cancel()
        processSource = nil
        // Deleting the sentinel makes any still-running wrapper exit and reap
        // kanata; the wrapper's app-pid poll is the backstop if this races.
        StopSentinel.remove()
    }

    // MARK: - Helpers

    /// Read the first newline-terminated line from `handle` and parse it as a pid.
    /// Blocks until data arrives or the pipe closes (EOF → returns nil).
    nonisolated private static func readPID(from handle: FileHandle) -> Int32? {
        var buf = ""
        while true {
            let data = handle.availableData
            if data.isEmpty { return nil }
            guard let chunk = String(data: data, encoding: .utf8) else { continue }
            for ch in chunk {
                if ch == "\n" {
                    return Int32(buf.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                buf.append(ch)
            }
        }
    }
}
