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
        kanataProcess.onStateChange = { [weak self] running in
            self?.updateMenuState()
            if !running {
                self?.currentLayer = "?"
                self?.updateIcon(layer: nil)
            }
        }
        kanataProcess.onStderr = { line in
            print("kanata: \(line)")
        }

        // Setup TCP client for layer tracking
        kanataClient = KanataClient(port: port)
        kanataClient.onLayerChange = { [weak self] layer in
            self?.currentLayer = layer
            self?.updateIcon(layer: layer)
            self?.updateMenuState()
        }
        kanataClient.onConnectionChange = { [weak self] connected in
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
            kanataProcess.start()
        }

        kanataClient.start()
        print("kanata-bar started (binary=\(binaryPath), config=\(configPath), port=\(port))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop kanata when kanata-bar exits
        kanataClient.stop()
        if kanataProcess.isRunning {
            kanataProcess.stop()
            // Brief wait for SIGTERM to take effect
            usleep(500_000)
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        layerItem = NSMenuItem(title: "Layer: \(currentLayer)", action: nil, keyEquivalent: "")
        menu.addItem(layerItem)
        menu.addItem(NSMenuItem.separator())

        startItem = NSMenuItem(title: "Start kanata", action: #selector(doStart), keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop kanata", action: #selector(doStop), keyEquivalent: "")
        reloadItem = NSMenuItem(title: "Reload config", action: #selector(doReload), keyEquivalent: "")
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q"))

        statusItem.menu = menu
        updateMenuState()
    }

    func updateMenuState() {
        let running = kanataProcess.isRunning
        layerItem?.title = "Layer: \(currentLayer)"
        startItem?.isEnabled = !running
        startItem?.isHidden = running
        stopItem?.isEnabled = running
        stopItem?.isHidden = !running
        reloadItem?.isEnabled = running
        reloadItem?.isHidden = !running
    }

    // MARK: - Icons

    func updateIcon(layer: String?) {
        guard let layer else {
            // Show placeholder icon while kanata is not connected
            if let image = loadPlaceholder() {
                statusItem?.button?.image = image
                statusItem?.button?.title = ""
            } else {
                statusItem?.button?.image = nil
                statusItem?.button?.title = "K?"
            }
            return
        }

        if let dir = iconsDir, let image = loadIcon(layer: layer, from: dir) {
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = String(layer.prefix(1)).uppercased()
        }
    }

    func loadPlaceholder() -> NSImage? {
        if let cached = iconCache["__placeholder"] { return cached }

        // Try icons dir first, then app bundle Resources
        let candidates = [
            iconsDir.map { "\($0)/placeholder.png" },
            Bundle.main.path(forResource: "placeholder", ofType: "png")
        ].compactMap { $0 }

        for path in candidates {
            if let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                iconCache["__placeholder"] = image
                return image
            }
        }
        return nil
    }

    func loadIcon(layer: String, from dir: String) -> NSImage? {
        if let cached = iconCache[layer] { return cached }

        let path = "\(dir)/\(layer).png"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        iconCache[layer] = image
        return image
    }

    // MARK: - Actions

    @objc func doStart() {
        kanataProcess.start()
    }

    @objc func doStop() {
        kanataProcess.stop()
    }

    @objc func doReload() {
        kanataClient.sendReload()
    }

    @objc func doQuit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helper

    func registerHelperIfNeeded() {
        let service = SMAppService.daemon(plistName: "com.kanata-bar.helper.plist")
        switch service.status {
        case .enabled:
            return // already registered
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
