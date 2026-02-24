import AppKit

extension AppDelegate {
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

    @objc func doQuit() {
        NSApplication.shared.terminate(nil)
    }
}
