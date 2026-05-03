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
            // Wrap kanata so its pid lands on sudo's stdout deterministically,
            // instead of guessing via pgrep after a fixed delay.
            let script = "\(kanataArgs)\(logRedirect) & echo $!; wait $!"

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
                    self.discoveredPID = -1
                    self.stoppedByUser = false
                    if !wasStopped && !pidWasDiscovered && exitCode != 0 {
                        self.onEvent?(.failed)
                    } else {
                        self.onEvent?(.exited(code: exitCode))
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
        // sudo may still be waiting for auth — kill it
        if let proc = sudoProcess, proc.isRunning {
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

    // MARK: - Cleanup

    func cleanup() {
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
