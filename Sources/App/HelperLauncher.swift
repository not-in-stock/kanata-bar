import Foundation
import Shared

/// Launches kanata as a child of the root XPC helper (task 15 supervisor path).
///
/// Zero prompts after the one-time Login Items approval: the helper is already
/// root, so it `posix_spawn`s kanata directly and a pre-granted TCC entry is
/// honoured (proven by the phase-0 spike). The app opens the log file and hands
/// the helper a `FileHandle` — the helper never opens app-supplied paths as root.
///
/// kanata's lifetime is tied to this one long-lived XPC connection: if the app
/// dies, the connection invalidates and the helper SIGKILLs kanata. Child exit
/// is detected client-side with the same `DispatchSourceProcess` pattern as
/// `AuthExecLauncher`, keeping the XPC protocol one-directional.
///
/// Experimental / default off — gated behind `launcher = "helper"` plus an
/// `.enabled` helper and an unchanged TCC fingerprint. Real cdhash consent is
/// phase 2.
@MainActor
final class HelperLauncher: KanataLauncher {
    nonisolated let binaryPath: String
    nonisolated let configPath: String
    nonisolated let port: UInt16
    nonisolated let extraArgs: [String]
    nonisolated let logURL: URL?

    private var connection: NSXPCConnection?
    private var logHandle: FileHandle?
    private var processSource: DispatchSourceProcess?
    private var monitoredPID: Int32 = -1

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
        teardownConnection()

        // App opens the log file; helper only receives the handle.
        var handle: FileHandle?
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            handle = FileHandle(forWritingAtPath: logURL.path)
        }
        logHandle = handle

        let conn = NSXPCConnection(machServiceName: HelperConfig.machServiceName, options: .privileged)
        conn.remoteObjectInterface = HelperInterface.make()
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleConnectionDrop(interrupted: false) }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleConnectionDrop(interrupted: true) }
        }
        conn.resume()
        connection = conn

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in self?.onEvent?(.error("helper unavailable: \(error.localizedDescription)")) }
        }) as? HelperProtocol else {
            onEvent?(.failed)
            return
        }

        let kanataArgs = ["-c", configPath, "--port", "\(port)"] + extraArgs
        proxy.startKanata(path: binaryPath, args: kanataArgs, log: handle) { [weak self] pid, message in
            Task { @MainActor in
                guard let self else { return }
                if pid > 0 {
                    self.monitoredPID = pid
                    self.onEvent?(.started(pid: pid))
                    self.startProcessMonitor(pid: pid)
                } else {
                    self.onEvent?(.error("helper failed to launch kanata: \(message)"))
                    self.onEvent?(.failed)
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        // Best-effort graceful stop; the helper SIGKILLs its child. The
        // connection-invalidation kill in cleanup() is the guaranteed backstop.
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperProtocol else { return }
        proxy.stopKanata { _, _ in }
    }

    // MARK: - Cleanup

    func cleanup() {
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperProtocol {
            proxy.stopKanata { _, _ in }
        }
        // Invalidating the connection also triggers the helper's own
        // invalidation-kill — kanata dies even if the async stopKanata is lost.
        teardownConnection()
    }

    // MARK: - Process Monitor

    private func startProcessMonitor(pid: Int32) {
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.processSource = nil
            self.monitoredPID = -1
            self.onEvent?(.exited(code: 1))
        }
        source.resume()
        processSource = source

        // Safety net: if kanata exited before kevent registration, the handler
        // never fires. Detect it immediately.
        if !isProcessAlive(pid) {
            processSource?.cancel()
            processSource = nil
            monitoredPID = -1
            onEvent?(.exited(code: 1))
        }
    }

    // MARK: - Connection

    /// The helper connection dropped (helper crash/restart). kanata is reparented
    /// to launchd, not killed, so the client process monitor stays authoritative;
    /// just note it. Phase 2 adds orphan adoption.
    private func handleConnectionDrop(interrupted: Bool) {
        guard monitoredPID > 0 else { return }
        onEvent?(.error("helper connection \(interrupted ? "interrupted" : "invalidated") while kanata pid \(monitoredPID) runs"))
    }

    private func teardownConnection() {
        processSource?.cancel()
        processSource = nil
        monitoredPID = -1
        if let conn = connection {
            conn.invalidationHandler = nil
            conn.interruptionHandler = nil
            conn.invalidate()
        }
        connection = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
