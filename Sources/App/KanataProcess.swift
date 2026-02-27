import Foundation
import ServiceManagement
import Shared

/// Manages the kanata process lifecycle.
/// Start via sudo (user session → TCC dialog works).
/// Stop via XPC helper (root → SIGTERM) or sudoers fallback.
class KanataProcess {
    enum StopMode { case xpc, sudoers }

    private var sudoProcess: Process?
    private var stoppedByUser = false
    private var startTimeoutWork: DispatchWorkItem?
    private(set) var kanataPID: Int32 = -1
    private(set) var isRunning = false
    private(set) var stopMode: StopMode

    let binaryPath: String
    let configPath: String
    let port: UInt16
    let extraArgs: [String]
    var kanataLogURL: URL?

    var onStateChange: ((Bool) -> Void)?
    var onPIDFound: ((Int32) -> Void)?
    var onError: ((String) -> Void)?
    var onCrash: ((Int32) -> Void)?
    var onStartFailure: (() -> Void)?

    init(binaryPath: String, configPath: String, port: UInt16, extraArgs: [String] = []) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.stopMode = Self.detectStopMode()
    }

    private static func detectStopMode() -> StopMode {
        let service = SMAppService.daemon(plistName: Constants.helperPlistName)
        return service.status == .enabled ? .xpc : .sudoers
    }

    func start() {
        guard !isRunning else { return }
        stoppedByUser = false
        isRunning = true
        onStateChange?(true)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Kill any leftover kanata (non-interactive: don't prompt for password)
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            pkill.arguments = ["-n", "/usr/bin/pkill", "-x", "kanata"]
            pkill.standardInput = FileHandle.nullDevice
            try? pkill.run()
            pkill.waitUntilExit()

            // Start kanata via sudo (user session context → TCC dialog will appear)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = [self.binaryPath, "-c", self.configPath, "--port", "\(self.port)"] + self.extraArgs

            // Redirect stdout+stderr to log file
            if let logURL = self.kanataLogURL {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                let logHandle = try? FileHandle(forWritingTo: logURL)
                p.standardOutput = logHandle
                p.standardError = logHandle
            }

            p.terminationHandler = { [weak self] proc in
                let exitCode = proc.terminationStatus
                DispatchQueue.main.async {
                    self?.startTimeoutWork?.cancel()
                    self?.startTimeoutWork = nil
                    let wasStopped = self?.stoppedByUser ?? true
                    let hadPID = self?.kanataPID ?? -1 > 0
                    self?.isRunning = false
                    self?.kanataPID = -1
                    self?.sudoProcess = nil
                    self?.onStateChange?(false)
                    if !wasStopped && exitCode != 0 {
                        if hadPID {
                            self?.onCrash?(exitCode)
                        } else {
                            self?.onStartFailure?()
                        }
                    }
                }
            }

            do {
                try p.run()
                self.sudoProcess = p

                // Timeout: if no kanata PID found within 30s, sudo likely hung
                // (e.g. waiting for password after TouchID cancel)
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.isRunning, self.kanataPID == -1 else { return }
                    self.startTimeoutWork = nil
                    // Kill the hung sudo process, then report failure
                    self.stoppedByUser = true
                    if let proc = self.sudoProcess, proc.isRunning {
                        proc.terminate()
                    }
                    self.isRunning = false
                    self.kanataPID = -1
                    self.sudoProcess = nil
                    self.onStateChange?(false)
                    self.onStartFailure?()
                }
                self.startTimeoutWork = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)

                // Find kanata PID after a short delay (sudo forks kanata as child)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.findKanataPID()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.onStateChange?(false)
                    self.onError?("failed to start kanata: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        startTimeoutWork?.cancel()
        startTimeoutWork = nil
        guard isRunning, kanataPID > 0 else {
            // sudo may still be waiting for auth — kill it
            if isRunning, let proc = sudoProcess, proc.isRunning {
                stoppedByUser = true
                proc.terminate()
            }
            return
        }
        stoppedByUser = true

        switch stopMode {
        case .xpc:
            stopViaXPC()
        case .sudoers:
            stopViaSudoers()
        }
    }

    // MARK: - XPC Stop

    private func stopViaXPC() {
        let conn = NSXPCConnection(machServiceName: HelperConfig.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            // Helper not available — fall back to sudoers
            self?.stopViaSudoers()
        } as! HelperProtocol

        let pid = kanataPID
        proxy.sendSignal(SIGTERM, toProcessID: pid) { [weak self] success, _ in
            if !success {
                self?.stopViaSudoers()
                return
            }
            // SIGKILL fallback after 3 seconds
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

    private func stopViaSudoers() {
        let pid = kanataPID
        guard pid > 0 else { return }

        sudoKill(signal: "TERM", pid: pid)

        // SIGKILL escalation after 3 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.isRunning else { return }
            // Check if process is still alive
            if self.isProcessAlive(pid) {
                self.sudoKill(signal: "KILL", pid: pid)
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

    private func isProcessAlive(_ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/kill")
        p.arguments = ["-0", "\(pid)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: - Detection

    static func findExternalKanataPID() -> Int32? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "kanata"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        try? pgrep.run()
        pgrep.waitUntilExit()
        guard pgrep.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(output.components(separatedBy: "\n").first ?? "") else { return nil }
        return pid
    }

    // MARK: - PID Discovery

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
                self.startTimeoutWork?.cancel()
                self.startTimeoutWork = nil
                self.kanataPID = pid
                self.onPIDFound?(pid)
            }
        }
    }
}
