import AppKit
import ServiceManagement
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var kanataClient: KanataClient!
    var kanataProcess: KanataProcess!

    var iconsDir: String?
    var iconCache: [String: NSImage] = [:]
    var currentLayer = "?"
    var autostart = true

    // Menu items that change state
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var reloadItem: NSMenuItem!
    var layerItem: NSMenuItem!
    var startingItem: NSMenuItem!
    var startAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Setup kanata process manager
        kanataProcess = KanataProcess(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: config.extraArgs)
        kanataProcess.kanataLogURL = kanataLogURL
        kanataProcess.onStateChange = { [weak self] running in
            if !running {
                self?.log("kanata stopped")
            }
            self?.updateMenuState()
            if !running {
                self?.currentLayer = "?"
                self?.updateIcon(layer: nil)
            }
        }
        kanataProcess.onPIDFound = { [weak self] pid in
            self?.log("kanata started (pid=\(pid))")
        }
        kanataProcess.onError = { [weak self] msg in
            self?.log("ERROR: \(msg)")
        }
        kanataProcess.onCrash = { [weak self] exitCode in
            self?.log("kanata crashed (exit code \(exitCode))")
            self?.sendCrashNotification()
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
            self?.log("layer: \(layer)")
            self?.currentLayer = layer
            self?.updateIcon(layer: layer)
            self?.updateMenuState()
        }
        var wasConnected = false
        kanataClient.onConnectionChange = { [weak self] connected in
            if connected != wasConnected {
                self?.log("TCP \(connected ? "connected" : "disconnected")")
                wasConnected = connected
            }
            if !connected {
                self?.currentLayer = "?"
                self?.updateIcon(layer: nil)
                self?.updateMenuState()
            }
        }

        // Build menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(layer: nil)
        buildMenu()

        // Register helper only when using XPC mode
        if kanataProcess.stopMode == .xpc {
            registerHelperIfNeeded()
        }

        // Auto-start kanata
        if autostart {
            log("starting kanata: \(binaryPath) -c \(configPath) --port \(port)")
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

    func applicationWillTerminate(_ notification: Notification) {
        kanataClient.stop()
        if kanataProcess.isRunning {
            kanataProcess.stop()
            usleep(500_000)
        }
    }

    // MARK: - Crash Notification

    func userNotificationCenter(_ center: UNUserNotificationCenter,
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
