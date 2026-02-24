import AppKit

extension AppDelegate {
    func buildMenu() {
        let menu = NSMenu()

        layerItem = NSMenuItem(title: String(format: NSLocalizedString("menu.layer", comment: ""), currentLayer), action: nil, keyEquivalent: "")
        menu.addItem(layerItem)
        menu.addItem(NSMenuItem.separator())

        startItem = NSMenuItem(title: NSLocalizedString("menu.start", comment: ""), action: #selector(doStart), keyEquivalent: "")
        stopItem = NSMenuItem(title: NSLocalizedString("menu.stop", comment: ""), action: #selector(doStop), keyEquivalent: "")
        reloadItem = NSMenuItem(title: NSLocalizedString("menu.reload", comment: ""), action: #selector(doReload), keyEquivalent: "")
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        startAtLoginItem = NSMenuItem(title: NSLocalizedString("menu.startAtLogin", comment: ""), action: #selector(doToggleAgent), keyEquivalent: "")
        startAtLoginItem.state = isAgentInstalled ? .on : .off
        menu.addItem(startAtLoginItem)
        let logsItem = NSMenuItem(title: NSLocalizedString("menu.logs", comment: ""), action: nil, keyEquivalent: "")
        let logsSubmenu = NSMenu()
        logsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("menu.logs.app", comment: ""), action: #selector(doViewAppLog), keyEquivalent: ""))
        logsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("menu.logs.kanata", comment: ""), action: #selector(doViewKanataLog), keyEquivalent: ""))
        logsItem.submenu = logsSubmenu
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(doQuit), keyEquivalent: "q"))

        statusItem.menu = menu
        updateMenuState()
    }

    func updateMenuState() {
        let running = kanataProcess.isRunning
        layerItem?.title = String(format: NSLocalizedString("menu.layer", comment: ""), currentLayer)
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
