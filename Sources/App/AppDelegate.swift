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

    var currentLayer: String? {
        if case .running(let layer) = appState { return layer }
        return nil
    }

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
        let usePamTid = Config.resolvePamTid(config.kanata.pamTid)

        let launcher: KanataLauncher
        if usePamTid {
            launcher = SudoLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.kanata.extraArgs, logURL: kanataLogURL)
        } else {
            launcher = AuthExecLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.kanata.extraArgs, logURL: kanataLogURL)
        }
        kanataProcess = KanataProcess(launcher: launcher, binaryPath: binaryPath, configPath: configPath, port: port)
        kanataProcess.onStateChange = { [weak self] running in
            if !running {
                self?.log("kanata stopped")
                self?.appState = .stopped
            }
        }
        kanataProcess.onPIDFound = { [weak self] pid in
            self?.log("kanata started (pid=\(pid))")
        }
        kanataProcess.onError = { [weak self] msg in
            self?.log("ERROR: \(msg)")
        }
        kanataProcess.onStartFailure = { [weak self] in
            self?.log("kanata failed to start (auth denied)")
            self?.appState = .stopped
            Notifications.sendStartFailure()
        }
        kanataProcess.onEarlyExit = { [weak self] exitCode in
            self?.log("kanata exited immediately (exit code \(exitCode))")
            self?.appState = .stopped
            Notifications.sendCrash()
        }
        kanataProcess.onCrash = { [weak self] exitCode in
            self?.log("kanata crashed (exit code \(exitCode))")
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
        kanataClient.onConfigReload = { [weak self] in
            self?.log("config reloaded")
            Notifications.sendReload()
        }
        kanataClient.onLayerChange = { [weak self] layer in
            guard let self else { return }
            self.log("layer: \(layer)")
            self.externalTimeoutWork?.cancel()
            self.externalTimeoutWork = nil
            self.appState = .running(layer)
        }
        var wasConnected = false
        kanataClient.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if connected != wasConnected {
                self.log("TCP \(connected ? "connected" : "disconnected")")
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
            log("detected external kanata (pid=\(pid)), connecting...")
            isExternal = true
            externalPID = pid
            appState = .starting
        } else if autostart {
            let binaryPath = kanataProcess.binaryPath
            if Config.isBinaryAccessible(binaryPath) {
                log("starting kanata: \(binaryPath) -c \(kanataProcess.configPath) --port \(kanataProcess.port)")
                appState = .starting
                kanataProcess.start()
            } else {
                log("ERROR: kanata binary not found: \(binaryPath)")
                Notifications.sendBinaryNotFound()
            }
        }
    }

    private func logStartupInfo() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log("starting [version=\(version)]")
        log("kanata binary: \(kanataProcess.binaryPath)")
        log("kanata config: \(kanataProcess.configPath)")
        log("TCP port: \(kanataProcess.port)")
        if let dir = iconManager.iconsDir { log("icons dir: \(dir)") }
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
            self.log("external kanata not responding, stopping")
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
            log("autorestart disabled: too many crashes")
            autorestart = false
            appState = .stopped
            Notifications.sendAutorestartDisabled()
            Notifications.sendCrash()
            return
        }
        restartTimestamps.append(now)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.appState == .restarting else { return }
            self.restartWorkItem = nil
            guard Config.isBinaryAccessible(self.kanataProcess.binaryPath) else {
                self.log("ERROR: kanata binary not found: \(self.kanataProcess.binaryPath)")
                self.appState = .stopped
                Notifications.sendBinaryNotFound()
                return
            }
            self.log("autorestarting kanata...")
            self.appState = .starting
            self.kanataProcess.start()
            Notifications.sendRestart()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - TCC

    private func resetTCCIfSourceChanged() {
        let currentSource = installSource()
        let previousSource = UserDefaults.standard.string(forKey: "installSource")

        if let previous = previousSource, previous != currentSource {
            log("install source changed (\(previous) → \(currentSource)), resetting TCC")
            let tccutil = Process()
            tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccutil.arguments = ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? Constants.bundleID]
            try? tccutil.run()
            tccutil.waitUntilExit()
        }

        UserDefaults.standard.set(currentSource, forKey: "installSource")
    }

    private func installSource() -> String {
        let path = Bundle.main.bundlePath
        if path.contains("/nix/store/") { return "nix" }
        if path.contains("/opt/homebrew/") || path.contains("/usr/local/Caskroom/") { return "homebrew" }
        return "other"
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
