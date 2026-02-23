import AppKit
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let serviceName = "com.kanata-bar.test-helper"
    let plistName = "com.kanata-bar.test-helper.plist"

    // Paths — adjust for your system
    let kanataBinary = "/run/current-system/sw/bin/kanata"
    let kanataConfig: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // TODO: use ~/.config/kanata/kanata.kbd after darwin-rebuild switch
        return "\(home)/Library/Application Support/kanata/kanata.kbd"
    }()
    let kanataPort = 5829

    // Track the sudo process and kanata PID
    var sudoProcess: Process?
    var kanataPID: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "KB"

        rebuildMenu(running: false)

        print("App started. Bundle: \(Bundle.main.bundlePath)")
        print("kanata binary: \(kanataBinary)")
        print("kanata config: \(kanataConfig)")

        let service = SMAppService.daemon(plistName: plistName)
        print("Helper status: \(statusString(service.status))")
    }

    func rebuildMenu(running: Bool) {
        let menu = NSMenu()

        if running {
            menu.addItem(menuItem("kanata: running (pid \(kanataPID))", action: nil, key: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem("Stop kanata", action: #selector(stopKanata), key: ""))
        } else {
            menu.addItem(menuItem("kanata: stopped", action: nil, key: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem("Start kanata", action: #selector(startKanata), key: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Register Helper", action: #selector(registerHelper), key: "r"))
        menu.addItem(menuItem("Unregister Helper", action: #selector(unregisterHelper), key: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("Quit", action: #selector(quitApp), key: "q"))

        statusItem.menu = menu
    }

    func menuItem(_ title: String, action: Selector?, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    // MARK: - Start kanata (from app — user session, TCC dialog works)

    @objc func startKanata() {
        print("\n--- Starting kanata ---")

        // Kill any leftover kanata first
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pkill.arguments = ["/usr/bin/pkill", "-x", "kanata"]
        try? pkill.run()
        pkill.waitUntilExit()

        // Start kanata via sudo (user session context → TCC dialog will appear)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = [kanataBinary, "-c", kanataConfig, "--port", "\(kanataPort)"]

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                print("kanata stderr: \(line.trimmingCharacters(in: .newlines))")
            }
        }

        p.terminationHandler = { [weak self] proc in
            print("sudo+kanata terminated: status=\(proc.terminationStatus)")
            DispatchQueue.main.async {
                self?.kanataPID = -1
                self?.sudoProcess = nil
                self?.rebuildMenu(running: false)
                self?.statusItem.button?.title = "KB"
            }
        }

        do {
            try p.run()
            sudoProcess = p
            print("sudo+kanata started (sudo pid=\(p.processIdentifier))")

            // Wait a moment for kanata to start, then find its PID
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.findKanataPID()
            }
        } catch {
            print("failed to start: \(error)")
        }
    }

    func findKanataPID() {
        // Find kanata PID (not sudo, not us)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "kanata"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(output.components(separatedBy: "\n").last ?? "") {
            kanataPID = pid
            print("kanata PID: \(pid)")
            DispatchQueue.main.async {
                self.rebuildMenu(running: true)
                self.statusItem.button?.title = "K"
            }
        } else {
            print("could not find kanata PID")
        }
    }

    // MARK: - Stop kanata (via helper — root can SIGTERM any process)

    @objc func stopKanata() {
        print("\n--- Stopping kanata (pid=\(kanataPID)) ---")

        guard kanataPID > 0 else {
            print("no kanata PID to stop")
            return
        }

        let conn = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()

        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            print("XPC error: \(error)")
        } as! HelperProtocol

        let pid = kanataPID
        proxy.sendSignal(SIGTERM, toProcessID: pid) { success, msg in
            print("stop: \(msg)")
            if success {
                // Wait for kanata to exit, then SIGKILL if needed
                DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                    proxy.isProcessAlive(pid) { alive in
                        if alive {
                            print("kanata still alive, sending SIGKILL")
                            proxy.sendSignal(SIGKILL, toProcessID: pid) { _, msg in
                                print("SIGKILL: \(msg)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Quit (stop kanata first if running)

    @objc func quitApp() {
        if kanataPID > 0 {
            stopKanata()
            // Give it a moment to stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helper registration

    @objc func registerHelper() {
        print("\n--- Registering helper ---")
        let service = SMAppService.daemon(plistName: plistName)
        print("Status before: \(statusString(service.status))")
        do {
            try service.register()
            print("register() succeeded")
        } catch {
            print("register() failed: \(error)")
        }
        print("Status after: \(statusString(service.status))")
    }

    @objc func unregisterHelper() {
        print("\n--- Unregistering helper ---")
        let service = SMAppService.daemon(plistName: plistName)
        do {
            try service.unregister()
            print("unregister() succeeded")
        } catch {
            print("unregister() failed: \(error)")
        }
        print("Status: \(statusString(service.status))")
    }

    func statusString(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

@main
enum App {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
