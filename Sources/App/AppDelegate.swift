import AppKit
import ServiceManagement
import Shared
import UserNotifications

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var kanataClient: KanataClient!
    var kanataProcess: KanataProcess!
    var iconManager: IconManager!

    var appState: AppState = .stopped {
        didSet {
            guard appState != oldValue else { return }
            iconManager?.updateAnimated(for: appState)
            updateMenuState()

            if case .starting = appState, !isExternal {
                scheduleStartingTimeout()
            } else {
                startingTimeoutTask?.cancel()
                startingTimeoutTask = nil
            }
        }
    }
    var isExternal = false
    var externalPID: Int32 = -1
    var externalTimeoutTask: Task<Void, Never>?
    var autostart = false
    var autorestart = false
    var crashRateLimiter = CrashRateLimiter()
    var restartTask: Task<Void, Never>?
    var startingTimeoutTask: Task<Void, Never>?
    var binaryNotFoundNotified = false

    // Menu items that change state
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var reloadItem: NSMenuItem!
    var layerItem: NSMenuItem!
    var startingItem: NSMenuItem!
    var startingLabel: NSTextField!
    var startingLeading: NSLayoutConstraint!
    var kanataSectionItem: NSMenuItem!
    var startAtLoginItem: NSMenuItem!
    var kanataLogsItem: NSMenuItem!
    var permissionsItem: NSMenuItem!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAlreadyRunning() else { return }
        Logging.truncateLog()

        let config = loadConfig()
        autostart = config.kanataBar.autostartKanata
        autorestart = config.kanataBar.autorestartKanata

        setupKanataProcess(config)
        setupNotificationPermission()
        setupTCPClient(port: config.kanata.port)
        setupMenuBar(config)

        registerHelperIfNeeded()
        resetTCCIfSourceChanged()
        preflightPermissions()
        migrateFromLaunchAgent()
        resolveLoginItemConflict()
        detectOrAutostart()

        kanataClient.start()
        logStartupInfo()
    }

    // MARK: - Startup

    private func isAlreadyRunning() -> Bool {
        let myBundleID = Bundle.main.bundleIdentifier ?? Constants.bundleID
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
        if running.count > 1 {
            print("kanata-bar is already running, exiting.")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
            return true
        }
        return false
    }

    private func loadConfig() -> Config {
        let args = CommandLine.arguments

        let configFilePath: String?
        if let idx = args.firstIndex(of: Constants.CLI.configFile), idx + 1 < args.count {
            configFilePath = args[idx + 1]
        } else {
            configFilePath = nil
        }
        var config = Config.load(from: configFilePath)

        if let idx = args.firstIndex(of: Constants.CLI.kanata), idx + 1 < args.count {
            config.kanata.path = args[idx + 1]
        }
        if let idx = args.firstIndex(of: Constants.CLI.config), idx + 1 < args.count {
            config.kanata.config = args[idx + 1]
        }
        if let idx = args.firstIndex(of: Constants.CLI.port), idx + 1 < args.count, let p = UInt16(args[idx + 1]) {
            config.kanata.port = p
        }
        if let idx = args.firstIndex(of: Constants.CLI.iconsDir), idx + 1 < args.count {
            config.kanataBar.iconsDir = args[idx + 1]
        }
        if args.contains(Constants.CLI.noAutostart) {
            config.kanataBar.autostartKanata = false
        }

        return config
    }

    private func setupKanataProcess(_ config: Config) {
        let binaryPath = Config.resolveKanataPath(config.kanata.path)
        let configPath = Config.expandTilde(config.kanata.config)
        let port = config.kanata.port
        let usePamTid = Config.resolvePamTouchid(config.kanataBar.pamTouchid)

        let launcher: KanataLauncher
        let extraArgs = config.kanata.extraArgs
        let logURL = Logging.kanataLogURL
        if shouldUseHelperLauncher(config) {
            Logging.log("auth mode: helper supervisor (experimental)")
            launcher = HelperLauncher(
                binaryPath: binaryPath, configPath: configPath,
                port: port, extraArgs: extraArgs, logURL: logURL)
        } else if usePamTid {
            Logging.log("auth mode: pam_touchid")
            launcher = SudoLauncher(
                binaryPath: binaryPath, configPath: configPath,
                port: port, extraArgs: extraArgs, logURL: logURL)
        } else {
            Logging.log("auth mode: authexec")
            launcher = AuthExecLauncher(
                binaryPath: binaryPath, configPath: configPath,
                port: port, extraArgs: extraArgs, logURL: logURL)
        }
        kanataProcess = KanataProcess(launcher: launcher, binaryPath: binaryPath, configPath: configPath, port: port)
        kanataProcess.onStateChange = { [weak self] running in
            if !running {
                Logging.log("kanata stopped")
                self?.appState = .stopped
            }
        }
        kanataProcess.onPIDFound = { pid in
            Logging.log("kanata started (pid=\(pid))")
        }
        kanataProcess.onError = { msg in
            Logging.log("ERROR: \(msg)")
        }
        kanataProcess.onStartFailure = { [weak self] in
            Logging.log("kanata failed to start")
            self?.appState = .stopped
            Notifications.sendStartFailure()
        }
        kanataProcess.onEarlyExit = { [weak self] exitCode in
            Logging.log("kanata exited immediately (exit code \(exitCode))")
            self?.appState = .stopped
            Notifications.sendCrash()
        }
        kanataProcess.onCrash = { [weak self] exitCode in
            Logging.log("kanata crashed (exit code \(exitCode))")
            if self?.autorestart == true {
                self?.appState = .restarting
                self?.scheduleRestart()
            } else {
                self?.appState = .stopped
                Notifications.sendCrash()
            }
        }
    }

    /// Whether to route kanata through the root XPC helper supervisor.
    ///
    /// Experimental (`launcher = "helper"`), and only when the helper is actually
    /// `.enabled` and TCC was granted to the *current* binary. A root daemon
    /// cannot show the Input Monitoring dialog, so a first run or a fingerprint
    /// change must still bootstrap through a user-session launcher. This runs
    /// before `resetTCCIfSourceChanged()`, so `installSource` still holds the
    /// previously-registered fingerprint — exactly the comparison we want.
    private func shouldUseHelperLauncher(_ config: Config) -> Bool {
        guard config.kanataBar.launcher == "helper" else { return false }

        let service = SMAppService.daemon(plistName: Constants.helperPlistName)
        guard service.status == .enabled else {
            Logging.log("launcher=helper requested but helper not enabled (status \(service.status.rawValue)); using bootstrap launcher")
            return false
        }

        let stored = UserDefaults.standard.string(forKey: "installSource")
        guard let stored, stored == installFingerprint() else {
            Logging.log("launcher=helper requested but TCC fingerprint changed/unset; using bootstrap launcher to re-grant")
            return false
        }

        // `.enabled` is only a registration state — launchd can still refuse to
        // spawn the daemon (e.g. an unsigned/ad-hoc helper at full SIP,
        // OS_REASON_CODESIGNING). Probe it so we fall back to bootstrap instead of
        // hanging HelperLauncher on a connection that never comes up.
        guard HelperLauncher.isResponding() else {
            Logging.log("launcher=helper enabled but helper not responding (can't spawn — needs signing at full SIP?); using bootstrap launcher")
            return false
        }

        return true
    }

    private func setupNotificationPermission() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupTCPClient(port: UInt16) {
        kanataClient = KanataClient(port: port)
        kanataClient.onConfigReload = {
            Logging.log("config reloaded")
            Notifications.sendReload()
        }
        kanataClient.onLayerChange = { [weak self] layer in
            guard let self else { return }
            Logging.log("layer: \(layer)")
            self.externalTimeoutTask?.cancel()
            self.externalTimeoutTask = nil
            self.appState = .running(layer)
        }
        var wasConnected = false
        kanataClient.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if connected != wasConnected {
                Logging.log("TCP \(connected ? "connected" : "disconnected")")
                wasConnected = connected
            }
            if connected {
                self.externalTimeoutTask?.cancel()
                self.externalTimeoutTask = nil
            }
            if !connected {
                if case .running = self.appState {
                    self.appState = .starting
                }
                if self.isExternal {
                    self.scheduleExternalTimeout()
                }
            }
        }
    }

    private func setupMenuBar(_ config: Config) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Kanata Bar"
        iconManager = IconManager(button: statusItem.button)
        iconManager.iconsDir = config.kanataBar.iconsDir.map { Config.expandTilde($0) }
        iconManager.transitionConfig = config.kanataBar.iconTransition
        iconManager.updateIcon(for: appState)
        buildMenu()
    }

    private func detectOrAutostart() {
        if let pid = KanataProcess.findExternalKanataPID() {
            Logging.log("detected external kanata (pid=\(pid)), connecting...")
            isExternal = true
            externalPID = pid
            appState = .starting
        } else if autostart {
            guard TCCPermissions.allGranted else {
                let missing = TCCPermissions.missing.map(TCCPermissions.label).joined(separator: ", ")
                Logging.log("autostart skipped: permissions not granted (\(missing))")
                Notifications.sendPermissionsNeeded()
                return
            }
            let binaryPath = kanataProcess.binaryPath
            if Config.isBinaryAccessible(binaryPath) {
                Logging.log("starting kanata: \(binaryPath) -c \(kanataProcess.configPath) --port \(kanataProcess.port)")
                appState = .starting
                kanataProcess.start()
            } else {
                Logging.log("ERROR: kanata binary not found: \(binaryPath)")
                binaryNotFoundNotified = true
                Notifications.sendBinaryNotFound()
            }
        }
    }

    private func logStartupInfo() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Logging.log("starting [version=\(version)]")
        Logging.log("kanata binary: \(kanataProcess.binaryPath)")
        Logging.log("kanata config: \(kanataProcess.configPath)")
        Logging.log("TCP port: \(kanataProcess.port)")
        if let dir = iconManager.iconsDir { Logging.log("icons dir: \(dir)") }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        restartTask?.cancel()
        restartTask = nil
        kanataClient.stop()
        guard !isExternal else { return }
        if kanataProcess.isRunning {
            kanataProcess.stop()
            usleep(Timing.cleanupGracePeriod)
        }
        kanataProcess.forceKillAll()
    }

    // MARK: - Notifications

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func scheduleStartingTimeout() {
        startingTimeoutTask?.cancel()
        let port = kanataProcess.port
        startingTimeoutTask = Task {
            try? await Task.sleep(for: Timing.tcpConnectTimeout)
            guard !Task.isCancelled, appState == .starting, !isExternal else { return }
            Logging.log("TCP not connected after 10s, port \(port) may be in use")
            Notifications.sendPortConflict(port: port)
        }
    }

    private func scheduleExternalTimeout() {
        externalTimeoutTask?.cancel()
        externalTimeoutTask = Task {
            try? await Task.sleep(for: Timing.externalKanataTimeout)
            guard !Task.isCancelled, isExternal, appState == .starting else { return }
            Logging.log("external kanata not responding, stopping")
            appState = .stopped
        }
    }

    private func scheduleRestart() {
        if !crashRateLimiter.recordCrash() {
            Logging.log("autorestart disabled: too many crashes")
            autorestart = false
            appState = .stopped
            Notifications.sendAutorestartDisabled()
            return
        }

        restartTask = Task {
            try? await Task.sleep(for: Timing.restartDelay)
            guard !Task.isCancelled, appState == .restarting else { return }
            guard Config.isBinaryAccessible(kanataProcess.binaryPath) else {
                Logging.log("ERROR: kanata binary not found: \(kanataProcess.binaryPath)")
                binaryNotFoundNotified = true
                appState = .stopped
                Notifications.sendBinaryNotFound()
                return
            }
            Logging.log("autorestarting kanata...")
            appState = .starting
            kanataProcess.start()
            Notifications.sendRestart()
        }
    }

    // MARK: - Logs

    @objc func doViewAppLog() {
        Logging.openInConsole(Logging.appLogURL)
    }

    @objc func doViewKanataLog() {
        Logging.openInConsole(Logging.kanataLogURL)
    }

    // MARK: - Helper

    func registerHelperIfNeeded() {
        let service = SMAppService.daemon(plistName: Constants.helperPlistName)

        // Detect an install-source switch (nix ↔ brew ↔ classic — all share
        // bundle-id com.kanata-bar). Such a switch can leave SMAppService
        // reporting a stale `.enabled` for a helper that no longer exists in
        // launchd/BTM: the shipped code then trusts `.enabled`, returns, and the
        // helper is silently absent with nothing to approve. We track the
        // fingerprint of the bundle we last registered from (separate key from
        // TCC's, so this doesn't depend on call order) and drop the stale record
        // when it changes.
        let fingerprint = installFingerprint()
        let lastRegistered = UserDefaults.standard.string(forKey: "helperInstallSource")
        if let lastRegistered, lastRegistered != fingerprint, service.status == .enabled {
            Logging.log("install source changed while helper .enabled — clearing stale registration")
            try? service.unregister()
        }

        switch service.status {
        case .enabled:
            UserDefaults.standard.set(fingerprint, forKey: "helperInstallSource")
        case .notRegistered, .requiresApproval, .notFound:
            do {
                try service.register()
                UserDefaults.standard.set(fingerprint, forKey: "helperInstallSource")
                Logging.log("helper registered (status: \(service.status.rawValue))")
            } catch {
                // register() reports "Operation not permitted" when the daemon is
                // registered but awaiting the user's approval in System Settings ›
                // General › Login Items & Extensions › Allow in the Background.
                Logging.log("helper awaiting approval in Login Items: \(error.localizedDescription)")
            }
        @unknown default:
            break
        }
    }

    // MARK: - Permissions

    /// Request the TCC grants kanata needs (Input Monitoring, Accessibility) from
    /// this user-session app, so a root-launched kanata inherits them. Only
    /// prompts for grants that are actually missing — a no-op once both are held.
    func preflightPermissions() {
        let missing = TCCPermissions.missing
        guard !missing.isEmpty else { return }
        Logging.log("requesting missing TCC grants: \(missing.map(TCCPermissions.label).joined(separator: ", "))")
        for kind in missing { TCCPermissions.request(kind) }
    }
}
