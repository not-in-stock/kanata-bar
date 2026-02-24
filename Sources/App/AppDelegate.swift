import AppKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
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
    var startAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.kanata-bar"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
        if running.count > 1 {
            print("kanata-bar is already running, exiting.")
            fflush(stdout)
            NSApplication.shared.terminate(nil)
            return
        }

        let args = CommandLine.arguments
        var port: UInt16 = 5829
        var binaryPath = "/run/current-system/sw/bin/kanata"
        var configPath = "\(NSHomeDirectory())/.config/kanata/kanata.kbd"

        if let idx = args.firstIndex(of: "--icons-dir"), idx + 1 < args.count {
            iconsDir = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count, let p = UInt16(args[idx + 1]) {
            port = p
        }
        if let idx = args.firstIndex(of: "--kanata"), idx + 1 < args.count {
            binaryPath = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "--config"), idx + 1 < args.count {
            configPath = args[idx + 1]
        }
        if args.contains("--no-autostart") {
            autostart = false
        }

        // Setup kanata process manager
        kanataProcess = KanataProcess(binaryPath: binaryPath, configPath: configPath, port: port)
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

        // Setup TCP client for layer tracking
        kanataClient = KanataClient(port: port)
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

    // MARK: - Helper

    func registerHelperIfNeeded() {
        let service = SMAppService.daemon(plistName: "com.kanata-bar.helper.plist")
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
