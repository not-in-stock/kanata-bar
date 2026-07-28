import Foundation
import ServiceManagement
import Shared

/// Launches kanata via `sudo -S` with PAM/TouchID support.
/// Stop via XPC helper or sudoers fallback.
@MainActor
class SudoLauncher: KanataLauncher {
    enum StopMode { case xpc, sudoers }

    nonisolated let binaryPath: String
    nonisolated let configPath: String
    nonisolated let port: UInt16
    nonisolated let extraArgs: [String]
    nonisolated let logURL: URL?

    private var sudoProcess: Process?
    private var discoveredPID: Int32 = -1
    private var stoppedByUser = false
    private(set) var stopMode: StopMode
    private var processSource: DispatchSourceProcess?

    var onEvent: ((LauncherEvent) -> Void)?

    init(binaryPath: String, configPath: String, port: UInt16, extraArgs: [String], logURL: URL?) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.logURL = logURL
        self.stopMode = Self.detectStopMode()
    }

    nonisolated private static func detectStopMode() -> StopMode {
        let service = SMAppService.daemon(plistName: Constants.helperPlistName)
        return service.status == .enabled ? .xpc : .sudoers
    }

    // MARK: - Start

    func start() {
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
            // Report kanata's pid on stdout deterministically, then self-clean:
            // an EXIT trap SIGKILLs kanata if this wrapper ever exits, and the
            // poll loop makes the wrapper exit when the app dies (crash or quit),
            // so kanata can't be orphaned when sudo/the wrapper is torn down.
            // kanata's own exit is tracked app-side via DispatchSourceProcess.
            // Mirrors AuthExecLauncher.
            let appPID = ProcessInfo.processInfo.processIdentifier
            let script = "\(kanataArgs)\(logRedirect) & KPID=$!; echo $KPID; "
                + "trap 'kill -KILL $KPID 2>/dev/null' EXIT; "
                + "while kill -0 \(appPID) 2>/dev/null; do sleep 0.2; done"

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
                    // monitor, and this wrapper now only exits when the app is
                    // going away — so don't surface that as a kanata event. Only
                    // report a pre-pid failure (auth denied / kanata never ran).
                    guard !pidWasDiscovered else { return }
                    self.stoppedByUser = false
                    if !wasStopped && exitCode != 0 {
                        self.onEvent?(.failed)
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
                    self.onEvent?(.started(pid: pid))
                    self.startProcessMonitor(pid: pid)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.onEvent?(.error("failed to start kanata: \(message)"))
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        stoppedByUser = true
        // Cancel a pending auth prompt only while kanata hasn't started yet.
        // Once it's running, terminating sudo would kill the wrapper shell
        // without running its EXIT trap (a default SIGTERM doesn't) and orphan
        // the backgrounded kanata — so SIGKILL kanata by pid instead.
        if discoveredPID <= 0, let proc = sudoProcess, proc.isRunning {
            proc.terminate()
            return
        }
        let pid = discoveredPID
        switch stopMode {
        case .xpc:
            stopViaXPC(pid: pid)
        case .sudoers:
            stopViaSudoers(pid: pid)
        }
    }

    // MARK: - Process Monitor

    /// Detect kanata's own exit (crash or an out-of-band kill) client-side, the
    /// same way `AuthExecLauncher` does — the sudo wrapper no longer `wait`s on
    /// kanata (it polls the app instead), so it can't report this.
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
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pkill.arguments = ["-n", "/usr/bin/pkill", "-x", Constants.kanataBinaryName]
        pkill.standardInput = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    // MARK: - XPC Stop

    private func stopViaXPC(pid: Int32? = nil) {
        guard let pid else {
            stopViaSudoers()
            return
        }
        let conn = NSXPCConnection(machServiceName: HelperConfig.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopViaSudoers(pid: pid)
            }
        }) as? HelperProtocol else { return }

        // kanata on macOS ignores SIGTERM — send SIGKILL directly
        proxy.sendSignal(SIGKILL, toProcessID: pid) { [weak self] success, _ in
            if !success {
                Task { @MainActor [weak self] in
                    self?.stopViaSudoers(pid: pid)
                }
            }
        }
    }

    // MARK: - Sudoers Stop

    private func stopViaSudoers(pid: Int32? = nil) {
        guard let pid, pid > 0 else { return }
        // kanata on macOS ignores SIGTERM — send SIGKILL directly
        sudoKill(signal: "KILL", pid: pid)
    }

    private func sudoKill(signal: String, pid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/bin/kill", "-\(signal)", "\(pid)"]
        p.standardInput = FileHandle.nullDevice
        try? p.run()
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
