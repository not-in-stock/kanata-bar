import Foundation
import ServiceManagement

/// Manages the kanata process lifecycle.
/// Start via sudo (user session → TCC dialog works).
/// Stop via XPC helper (root → SIGTERM) or sudoers fallback.
class KanataProcess {
    enum StopMode { case xpc, sudoers }

    private var sudoProcess: Process?
    private(set) var kanataPID: Int32 = -1
    private(set) var isRunning = false
    private(set) var stopMode: StopMode

    let binaryPath: String
    let configPath: String
    let port: UInt16
    var kanataLogURL: URL?

    var onStateChange: ((Bool) -> Void)?
    var onPIDFound: ((Int32) -> Void)?
    var onError: ((String) -> Void)?

    init(binaryPath: String, configPath: String, port: UInt16) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.stopMode = Self.detectStopMode()
    }

    private static func detectStopMode() -> StopMode {
        let service = SMAppService.daemon(plistName: "com.kanata-bar.helper.plist")
        return service.status == .enabled ? .xpc : .sudoers
    }

    func start() {
        guard !isRunning else { return }

        // Kill any leftover kanata
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pkill.arguments = ["/usr/bin/pkill", "-x", "kanata"]
        try? pkill.run()
        pkill.waitUntilExit()

        // Start kanata via sudo (user session context → TCC dialog will appear)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = [binaryPath, "-c", configPath, "--port", "\(port)"]

        // Redirect stdout+stderr to log file (like kanata-tray does)
        if let logURL = kanataLogURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try? FileHandle(forWritingTo: logURL)
            p.standardOutput = logHandle
            p.standardError = logHandle
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.kanataPID = -1
                self?.sudoProcess = nil
                self?.onStateChange?(false)
            }
        }

        do {
            try p.run()
            sudoProcess = p
            isRunning = true
            onStateChange?(true)

            // Find kanata PID after a short delay (sudo forks kanata as child)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.findKanataPID()
            }
        } catch {
            onError?("failed to start kanata: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning, kanataPID > 0 else { return }

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
        p.arguments = ["/bin/kill", "-\(signal)", "\(pid)"]
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
                self.kanataPID = pid
                self.onPIDFound?(pid)
            }
        }
    }
}
