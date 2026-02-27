import AppKit
import ServiceManagement
import Shared
import UserNotifications

public class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var kanataClient: KanataClient!
    var kanataProcess: KanataProcess!

    var iconsDir: String?
    var iconCache: [String: NSImage] = [:]
    var appState: AppState = .stopped {
        didSet {
            guard appState != oldValue else { return }
            updateIcon()
            updateMenuState()
        }
    }
    var isExternal = false
    var externalPID: Int32 = -1
    var externalTimeoutWork: DispatchWorkItem?
    var autostart = true
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
    var kanataSectionItem: NSMenuItem!
    var startAtLoginItem: NSMenuItem!
    var kanataLogsItem: NSMenuItem!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let myBundleID = Bundle.main.bundleIdentifier ?? Constants.bundleID
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
        if running.count > 1 {
            print("kanata-bar is already running, exiting.")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
            return
        }

        let args = CommandLine.arguments

        // Load config file
        let configFilePath: String?
        if let idx = args.firstIndex(of: Constants.CLI.configFile), idx + 1 < args.count {
            configFilePath = args[idx + 1]
        } else {
            configFilePath = nil
        }
        var config = Config.load(from: configFilePath)

        // CLI overrides
        if let idx = args.firstIndex(of: Constants.CLI.kanata), idx + 1 < args.count {
            config.kanata = args[idx + 1]
        }
        if let idx = args.firstIndex(of: Constants.CLI.config), idx + 1 < args.count {
            config.config = args[idx + 1]
        }
        if let idx = args.firstIndex(of: Constants.CLI.port), idx + 1 < args.count, let p = UInt16(args[idx + 1]) {
            config.port = p
        }
        if let idx = args.firstIndex(of: Constants.CLI.iconsDir), idx + 1 < args.count {
            config.iconsDir = args[idx + 1]
        }
        if args.contains(Constants.CLI.noAutostart) {
            config.autostart = false
        }

        let binaryPath = Config.resolveKanataPath(config.kanata)
        let configPath = Config.expandTilde(config.config)
        let port = config.port
        iconsDir = config.iconsDir.map { Config.expandTilde($0) }
        autostart = config.autostart
        autorestart = config.autorestart
        let usePamTid = Config.resolvePamTid(config.pamTid)

        // Setup kanata process manager
        let launcher: KanataLauncher
        if usePamTid {
            launcher = SudoLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.extraArgs, logURL: kanataLogURL)
        } else {
            launcher = AuthExecLauncher(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.extraArgs, logURL: kanataLogURL)
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
            self?.log("kanata failed to start (sudo denied or binary missing)")
            self?.appState = .stopped
            self?.sendStartFailureNotification()
        }
        kanataProcess.onCrash = { [weak self] exitCode in
            self?.log("kanata crashed (exit code \(exitCode))")
            if self?.autorestart == true {
                self?.appState = .restarting
                self?.scheduleRestart()
            } else {
                self?.appState = .stopped
                self?.sendCrashNotification()
            }
        }

        // Request notification permission
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Setup TCP client for layer tracking
        kanataClient = KanataClient(port: port)
        kanataClient.onConfigReload = { [weak self] in
            self?.log("config reloaded")
            self?.sendReloadNotification()
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

        // Build menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        buildMenu()

        registerHelperIfNeeded()

        // Detect external kanata or auto-start
        if let pid = KanataProcess.findExternalKanataPID() {
            log("detected external kanata (pid=\(pid)), connecting...")
            isExternal = true
            externalPID = pid
            appState = .starting
        } else if autostart {
            log("starting kanata: \(binaryPath) -c \(configPath) --port \(port)")
            appState = .starting
            kanataProcess.start()
        }

        kanataClient.start()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log("starting [version=\(version)]")
        log("kanata binary: \(binaryPath)")
        log("kanata config: \(configPath)")
        log("TCP port: \(port)")
        if let dir = iconsDir { log("icons dir: \(dir)") }
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

    // MARK: - Crash Notification

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func sendReloadNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.reload.title", comment: "")
        content.body = NSLocalizedString("notification.reload.body", comment: "")

        let request = UNNotificationRequest(identifier: "kanata-reload", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
            sendAutorestartDisabledNotification()
            sendCrashNotification()
            return
        }
        restartTimestamps.append(now)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.appState == .restarting else { return }
            self.restartWorkItem = nil
            self.log("autorestarting kanata...")
            self.appState = .starting
            self.kanataProcess.start()
            self.sendRestartNotification()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func sendRestartNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.restart.title", comment: "")
        content.body = NSLocalizedString("notification.restart.body", comment: "")

        let request = UNNotificationRequest(identifier: "kanata-restart", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendAutorestartDisabledNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.restart.disabled.title", comment: "")
        content.body = NSLocalizedString("notification.restart.disabled.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-restart-disabled", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendStartFailureNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.startFailure.title", comment: "")
        content.body = NSLocalizedString("notification.startFailure.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-start-failure", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func sendCrashNotification() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.crash.title", comment: "")
        content.body = NSLocalizedString("notification.crash.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-crash", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
