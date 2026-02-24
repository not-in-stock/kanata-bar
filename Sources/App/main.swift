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

    let appLogURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent("kanata-bar.log")
    }()

    let kanataLogURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent("kanata.log")
    }()

    // Menu items that change state
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var reloadItem: NSMenuItem!
    var layerItem: NSMenuItem!
    var startAtLoginItem: NSMenuItem!

    // MARK: - LaunchAgent

    static let agentLabel = "com.kanata-bar"
    static let agentPlistName = "\(agentLabel).plist"

    var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(Self.agentPlistName)"
    }

    var isAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    func buildLaunchAgentPlist() -> String {
        let skip: Set<String> = ["--install-agent", "--uninstall-agent", "--no-autostart", "--"]
        let args = CommandLine.arguments.filter { !skip.contains($0) }

        // Resolve binary path
        let binary: String
        let arg0 = args[0]
        if arg0.hasPrefix("/") {
            binary = arg0
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            binary = "\(cwd)/\(arg0)"
        }

        var programArgs = "        <string>\(binary)</string>"
        for arg in args.dropFirst() {
            programArgs += "\n        <string>\(arg)</string>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(programArgs)
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    func installAgent() {
        let dir = (launchAgentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let plist = buildLaunchAgentPlist()
        do {
            try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write LaunchAgent plist: \(error)")
        }
    }

    func uninstallAgent() {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }

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
            if !running {
                self?.log("kanata stopped")
            }
            self?.updateMenuState()
            if !running {
                self?.currentLayer = "?"
                self?.updateIcon(layer: nil)
            }
        }
        kanataProcess.onStderr = { [weak self] line in
            print("kanata: \(line)")
            self?.appendKanataLog(line)
        }
        kanataProcess.onPIDFound = { [weak self] pid in
            self?.log("kanata started (pid=\(pid))")
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

        startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(doToggleAgent), keyEquivalent: "")
        startAtLoginItem.state = isAgentInstalled ? .on : .off
        menu.addItem(startAtLoginItem)
        let logsItem = NSMenuItem(title: "Logs", action: nil, keyEquivalent: "")
        let logsSubmenu = NSMenu()
        logsSubmenu.addItem(NSMenuItem(title: "Kanata Bar", action: #selector(doViewAppLog), keyEquivalent: ""))
        logsSubmenu.addItem(NSMenuItem(title: "Kanata", action: #selector(doViewKanataLog), keyEquivalent: ""))
        logsItem.submenu = logsSubmenu
        menu.addItem(logsItem)

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
        log("starting kanata: \(kanataProcess.binaryPath) -c \(kanataProcess.configPath) --port \(kanataProcess.port)")
        kanataProcess.start()
    }

    @objc func doStop() {
        kanataProcess.stop()
    }

    @objc func doReload() {
        kanataClient.sendReload()
    }

    @objc func doToggleAgent() {
        if isAgentInstalled {
            uninstallAgent()
        } else {
            installAgent()
        }
        startAtLoginItem?.state = isAgentInstalled ? .on : .off
    }

    @objc func doViewAppLog() {
        openInConsole(appLogURL)
    }

    @objc func doViewKanataLog() {
        openInConsole(kanataLogURL)
    }

    private func openInConsole(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open([url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private let logDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func log(_ message: String) {
        let entry = "\(logDateFormatter.string(from: Date())) \(message)\n"
        print("kanata-bar: \(message)")
        appendToFile(appLogURL, entry)
    }

    func appendKanataLog(_ line: String) {
        let entry = "\(logDateFormatter.string(from: Date())) \(line)\n"
        appendToFile(kanataLogURL, entry)
    }

    private func appendToFile(_ url: URL, _ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
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

// Handle --install-agent / --uninstall-agent before starting the app
let cliArgs = CommandLine.arguments
if cliArgs.contains("--install-agent") {
    let helper = AppDelegate()
    helper.installAgent()
    print("LaunchAgent installed at \(helper.launchAgentPath)")
    exit(0)
} else if cliArgs.contains("--uninstall-agent") {
    let helper = AppDelegate()
    helper.uninstallAgent()
    print("LaunchAgent removed from \(helper.launchAgentPath)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
