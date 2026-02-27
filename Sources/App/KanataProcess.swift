import Foundation

/// Coordinates kanata lifecycle. Delegates launch/stop to a `KanataLauncher`.
class KanataProcess {
    private let launcher: KanataLauncher
    private var stoppedByUser = false
    private(set) var kanataPID: Int32 = -1
    private(set) var isRunning = false

    let binaryPath: String
    let configPath: String
    let port: UInt16

    var onStateChange: ((Bool) -> Void)?
    var onPIDFound: ((Int32) -> Void)?
    var onError: ((String) -> Void)?
    var onCrash: ((Int32) -> Void)?
    var onStartFailure: (() -> Void)?

    init(launcher: KanataLauncher, binaryPath: String, configPath: String, port: UInt16) {
        self.launcher = launcher
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        bindLauncher()
    }

    private func bindLauncher() {
        launcher.onStarted = { [weak self] pid in
            guard let self else { return }
            self.kanataPID = pid
            self.onPIDFound?(pid)
        }

        launcher.onExited = { [weak self] exitCode in
            guard let self else { return }
            let wasStopped = self.stoppedByUser
            let hadPID = self.kanataPID > 0
            self.isRunning = false
            self.kanataPID = -1
            self.onStateChange?(false)
            if !wasStopped && exitCode != 0 {
                if hadPID {
                    self.onCrash?(exitCode)
                } else {
                    self.onStartFailure?()
                }
            }
        }

        launcher.onFailure = { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.onStateChange?(false)
            self.onStartFailure?()
        }

        launcher.onError = { [weak self] msg in
            guard let self else { return }
            self.isRunning = false
            self.onStateChange?(false)
            self.onError?(msg)
        }
    }

    // MARK: - Start

    func start() {
        guard !isRunning else { return }
        stoppedByUser = false
        isRunning = true
        onStateChange?(true)
        launcher.start()
    }

    // MARK: - Stop

    func stop() {
        stoppedByUser = true
        launcher.stop()
    }

    // MARK: - Cleanup

    func forceKillAll() {
        launcher.cleanup()
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
}
