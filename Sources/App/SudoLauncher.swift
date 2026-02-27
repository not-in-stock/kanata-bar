import Foundation
import ServiceManagement
import Shared

/// Launches kanata via `sudo -S` with PAM/TouchID support.
/// Stop via XPC helper or sudoers fallback.
class SudoLauncher: KanataLauncher {
    enum StopMode { case xpc, sudoers }

    private let binaryPath: String
    private let configPath: String
    private let port: UInt16
    private let extraArgs: [String]
    private let logURL: URL?

    private var sudoProcess: Process?
    private var discoveredPID: Int32 = -1
    private(set) var stopMode: StopMode

    var onStarted: ((Int32) -> Void)?
    var onExited: ((Int32) -> Void)?
    var onFailure: (() -> Void)?
    var onError: ((String) -> Void)?

    init(binaryPath: String, configPath: String, port: UInt16, extraArgs: [String], logURL: URL?) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.logURL = logURL
        self.stopMode = Self.detectStopMode()
    }

    private static func detectStopMode() -> StopMode {
        let service = SMAppService.daemon(plistName: Constants.helperPlistName)
        return service.status == .enabled ? .xpc : .sudoers
    }

    // MARK: - Start

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            killLeftoverKanata()

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-S", binaryPath, "-c", configPath, "--port", "\(port)"] + extraArgs

            let stdinPipe = Pipe()
            stdinPipe.fileHandleForWriting.closeFile()
            p.standardInput = stdinPipe

            setupLogRedirect(for: p)

            p.terminationHandler = { [weak self] proc in
                let exitCode = proc.terminationStatus
                DispatchQueue.main.async {
                    self?.sudoProcess = nil
                    self?.discoveredPID = -1
                    self?.onExited?(exitCode)
                }
            }

            do {
                try p.run()
                sudoProcess = p
                schedulePIDDiscovery()
            } catch {
                DispatchQueue.main.async {
                    self.onError?("failed to start kanata: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
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
        pkill.arguments = ["-n", "/usr/bin/pkill", "-x", "kanata"]
        pkill.standardInput = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }

    // MARK: - XPC Stop

    private func stopViaXPC(pid: Int32? = nil) {
        // pid is passed from KanataProcess; fall back to sudoers if XPC fails
        guard let pid else {
            stopViaSudoers()
            return
        }
        let conn = NSXPCConnection(machServiceName: HelperConfig.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.stopViaSudoers(pid: pid)
        } as! HelperProtocol

        proxy.sendSignal(SIGTERM, toProcessID: pid) { [weak self] success, _ in
            if !success {
                self?.stopViaSudoers(pid: pid)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                proxy.isProcessAlive(pid) { alive in
                    if alive {
                        proxy.sendSignal(SIGKILL, toProcessID: pid) { _, _ in }
                    }
                }
            }
        }
    }

    // MARK: - Sudoers Stop

    private func stopViaSudoers(pid: Int32? = nil) {
        guard let pid, pid > 0 else { return }
        sudoKill(signal: "TERM", pid: pid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard self != nil else { return }
            if isProcessAlive(pid) {
                self?.sudoKill(signal: "KILL", pid: pid)
            }
        }
    }

    private func sudoKill(signal: String, pid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/bin/kill", "-\(signal)", "\(pid)"]
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - Helpers

    private func setupLogRedirect(for process: Process) {
        guard let logURL else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
    }

    private func schedulePIDDiscovery() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.findKanataPID()
        }
    }

    private func findKanataPID() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "kanata"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(output.components(separatedBy: "\n").last ?? "") {
            DispatchQueue.main.async {
                self.discoveredPID = pid
                self.onStarted?(pid)
            }
        }
    }
}
