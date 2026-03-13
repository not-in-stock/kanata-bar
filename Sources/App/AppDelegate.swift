import AppKit
import ServiceManagement
import Shared
import UserNotifications

public class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var kanataClient: KanataClient!
    var kanataProcess: KanataProcess!
    var iconManager: IconManager!

    var appState: AppState = .stopped {
        didSet {
            guard appState != oldValue else { return }
            iconManager?.updateAnimated(for: appState)
            updateMenuState()
        }
    }
    var isExternal = false
    var externalPID: Int32 = -1
    var externalTimeoutWork: DispatchWorkItem?
    var autostart = false
    var autorestart = false
    var restartTimestamps: [Date] = []
    var restartWorkItem: DispatchWorkItem?

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
        migrateFromLaunchAgent()
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

        Logging.log("auth mode: \(usePamTid ? "pam_touchid" : "authexec")")

        let launcher: KanataLauncher
        if usePamTid {
            launcher = SudoLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.kanata.extraArgs, logURL: Logging.kanataLogURL)
        } else {
            launcher = AuthExecLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.kanata.extraArgs, logURL: Logging.kanataLogURL)
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
            self.externalTimeoutWork?.cancel()
            self.externalTimeoutWork = nil
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
                self.externalTimeoutWork?.cancel()
                self.externalTimeoutWork = nil
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
            let binaryPath = kanataProcess.binaryPath
            if Config.isBinaryAccessible(binaryPath) {
                Logging.log("starting kanata: \(binaryPath) -c \(kanataProcess.configPath) --port \(kanataProcess.port)")
                appState = .starting
                kanataProcess.start()
            } else {
                Logging.log("ERROR: kanata binary not found: \(binaryPath)")
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
        restartWorkItem?.cancel()
        restartWorkItem = nil
        kanataClient.stop()
        guard !isExternal else { return }
        if kanataProcess.isRunning {
            kanataProcess.stop()
            usleep(500_000)
        }
        kanataProcess.forceKillAll()
    }

    // MARK: - Notifications

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func scheduleExternalTimeout() {
        externalTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isExternal, self.appState == .starting else { return }
            Logging.log("external kanata not responding, stopping")
            self.externalTimeoutWork = nil
            self.appState = .stopped
        }
        externalTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func scheduleRestart() {
        let now = Date()
        restartTimestamps = restartTimestamps.filter { now.timeIntervalSince($0) < 60 }
        if restartTimestamps.count >= 3 {
            Logging.log("autorestart disabled: too many crashes")
            autorestart = false
            appState = .stopped
            Notifications.sendAutorestartDisabled()
            return
        }
        restartTimestamps.append(now)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.appState == .restarting else { return }
            self.restartWorkItem = nil
            guard Config.isBinaryAccessible(self.kanataProcess.binaryPath) else {
                Logging.log("ERROR: kanata binary not found: \(self.kanataProcess.binaryPath)")
                self.appState = .stopped
                Notifications.sendBinaryNotFound()
                return
            }
            Logging.log("autorestarting kanata...")
            self.appState = .starting
            self.kanataProcess.start()
            Notifications.sendRestart()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - TCC

    private func resetTCCIfSourceChanged() {
        let currentPath = resolvedBundlePath()
        let previousPath = UserDefaults.standard.string(forKey: "installSource")

        if let previous = previousPath, previous != currentPath {
            Logging.log("install path changed (\(previous) → \(currentPath)), resetting TCC")
            let tccutil = Process()
            tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccutil.arguments = ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? Constants.bundleID]
            try? tccutil.run()
            tccutil.waitUntilExit()
        }

        UserDefaults.standard.set(currentPath, forKey: "installSource")
    }

    private func resolvedBundlePath() -> String {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        return url.resolvingSymlinksInPath().path
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
        switch service.status {
        case .enabled:
            return
        case .notRegistered, .requiresApproval:
            do {
                try service.register()
            } catch {
                print("helper registration failed: \(error) (falling back to sudo for stop)")
            }
        default:
            break
        }
    }
}
