import Foundation

/// Reloads kanata's config when the file is saved: watch → validate with
/// `kanata --check` → `Reload{wait:true}` → read the result.
///
/// Session-only state machine; nothing here touches the config file. The
/// watcher, checker and reload request are injected so the flow is testable
/// without kanata. All calls on the main actor.
@MainActor
final class AutoReloader {

    enum Status: Equatable {
        case off
        /// Enabled, waiting for a save.
        case armed
        case checking
        case reloading
        case reloaded(Date)
        /// `--check` rejected the file; kanata is still running the previous config.
        case invalid(summary: String)
        /// kanata accepted the request but the live reload did not succeed.
        case reloadFailed

        var isError: Bool {
            switch self {
            case .invalid, .reloadFailed: return true
            default: return false
            }
        }
    }

    struct Dependencies {
        var check: @Sendable (String) async -> ConfigChecker.Outcome
        var reload: @MainActor () -> Void
        /// Paths `include`d by the config, re-read after every successful reload.
        var includedPaths: @MainActor () -> [String]
        var makeWatcher: @MainActor ([String], @escaping @Sendable (ConfigWatcher.Change) -> Void) -> ConfigWatcher
    }

    let configPath: String
    private let deps: Dependencies
    private var watcher: ConfigWatcher?
    private var inFlight: Task<Void, Never>?
    private var reloadTimeout: Task<Void, Never>?

    private(set) var isEnabled = false
    private(set) var kanataRunning = false
    private(set) var status: Status = .off {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
            // `checking`/`reloading` are transient: a failing save after a failing
            // save is still the same error episode, so compare with the last settled state.
            switch status {
            case .checking, .reloading:
                return
            default:
                if status.isError, !settledInError { onEnterError?(status) }
                settledInError = status.isError
            }
        }
    }
    private var settledInError = false

    var onStatusChange: ((Status) -> Void)?
    /// Fired once per transition into an error state (for the one notification).
    var onEnterError: ((Status) -> Void)?
    var log: (String) -> Void = { Logging.log($0) }

    /// Our own cap on waiting for `ReloadResult`/`ConfigFileReload`; kanata's
    /// `wait` times out at 5 s, so anything longer means the reply was lost.
    static let reloadResultTimeout: TimeInterval = 8

    init(configPath: String, dependencies: Dependencies) {
        self.configPath = configPath
        self.deps = dependencies
    }

    // MARK: - Control

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            log("auto-reload: on")
            status = .armed
            syncWatcher()
        } else {
            log("auto-reload: off")
            cancelInFlight()
            status = .off
            syncWatcher()
        }
    }

    /// Stopping kanata pauses the watcher; starting resumes it. The status survives.
    func setKanataRunning(_ running: Bool) {
        guard running != kanataRunning else { return }
        kanataRunning = running
        if !running { cancelInFlight() }
        syncWatcher()
    }

    private func syncWatcher() {
        let shouldWatch = isEnabled && kanataRunning
        guard shouldWatch else {
            watcher?.stop()
            watcher = nil
            return
        }
        let paths = [configPath] + deps.includedPaths().filter { $0 != configPath }
        if let watcher, watcher.paths == paths {
            if !watcher.isActive { watcher.start() }
            return
        }
        watcher?.stop()
        let w = deps.makeWatcher(paths) { change in
            Task { @MainActor [weak self] in self?.fileChanged(change) }
        }
        watcher = w
        w.start()
        log("auto-reload: watching \(paths.joined(separator: ", "))")
    }

    // MARK: - Flow

    /// A debounced save arrived (from the watcher, or a test).
    func fileChanged(_ change: ConfigWatcher.Change) {
        guard isEnabled, kanataRunning else { return }
        cancelInFlight()
        log("auto-reload: changed \(change.triggeredPaths.joined(separator: ", "))")
        status = .checking
        let check = deps.check
        let path = configPath
        inFlight = Task { [weak self] in
            let outcome = await check(path)
            guard !Task.isCancelled, let self else { return }
            self.inFlight = nil
            self.handle(outcome)
        }
    }

    private func handle(_ outcome: ConfigChecker.Outcome) {
        switch outcome {
        case .valid:
            requestReload()
        case .invalid(let summary, let details):
            log("auto-reload: config invalid — \(summary)\n\(details)")
            status = .invalid(summary: summary)
        case .failed(let reason):
            // Cannot validate; let kanata be the judge rather than silently doing nothing.
            log("auto-reload: --check unavailable (\(reason)), reloading without pre-check")
            requestReload()
        }
    }

    private func requestReload() {
        status = .reloading
        deps.reload()
        reloadTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reloadResultTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status == .reloading else { return }
            self.log("auto-reload: no reload result from kanata")
            self.status = .reloadFailed
        }
    }

    /// `ReloadResult` from kanata (only meaningful while we wait for one).
    func reloadResult(ok: Bool, timedOut: Bool) {
        guard status == .reloading else { return }
        reloadTimeout?.cancel()
        if ok {
            finishReload()
        } else {
            log("auto-reload: kanata reported reload failure\(timedOut ? " (timed out)" : "")")
            status = .reloadFailed
        }
    }

    /// `ConfigFileReload` from kanata — also a success signal, and the point
    /// where the include list may have changed.
    func configReloaded() {
        guard status == .reloading else { return }
        reloadTimeout?.cancel()
        finishReload()
    }

    private func finishReload() {
        log("auto-reload: reloaded")
        status = .reloaded(Date())
        syncWatcher() // picks up a changed include list
    }

    private func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
        reloadTimeout?.cancel()
        reloadTimeout = nil
    }

    // MARK: - Wiring

    /// Production dependencies: real checker, watcher and TCP reload.
    static func live(configPath: String, binaryPath: String, client: KanataClient) -> AutoReloader {
        let checker = ConfigChecker(binaryPath: binaryPath)
        return AutoReloader(configPath: configPath, dependencies: Dependencies(
            check: { await checker.check(configPath: $0) },
            reload: { [weak client] in client?.sendReload(wait: true) },
            includedPaths: { KanataConfigParser.includedPaths(configPath: configPath) },
            makeWatcher: { paths, onChange in
                ConfigWatcher(paths: paths, debounce: Timing.configWatchDebounce, onChange: onChange)
            }
        ))
    }
}
