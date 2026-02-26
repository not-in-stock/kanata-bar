import AppKit

extension AppDelegate {
    func buildMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let signImage = NSImage(named: "sign") {
            let maxHeight: CGFloat = 18
            let scale = maxHeight / signImage.size.height
            let imageSize = NSSize(width: signImage.size.width * scale, height: maxHeight)
            signImage.size = imageSize
            signImage.isTemplate = true

            let imageView = NSImageView(image: signImage)
            imageView.imageScaling = .scaleProportionallyDown

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: maxHeight + 8))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: imageSize.width),
                imageView.heightAnchor.constraint(equalToConstant: imageSize.height),
            ])
            headerItem.view = container
        }
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Starting indicator with spinner
        startingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        startingItem.isEnabled = false
        let startingView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let startingLabel = NSTextField(labelWithString: NSLocalizedString("menu.starting", comment: ""))
        startingLabel.font = NSFont.menuFont(ofSize: 14)
        startingLabel.textColor = .secondaryLabelColor
        startingLabel.translatesAutoresizingMaskIntoConstraints = false
        startingView.addSubview(spinner)
        startingView.addSubview(startingLabel)
        NSLayoutConstraint.activate([
            startingLabel.leadingAnchor.constraint(equalTo: startingView.leadingAnchor, constant: 25),
            startingLabel.centerYAnchor.constraint(equalTo: startingView.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: startingView.trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: startingView.centerYAnchor),
        ])
        startingItem.view = startingView
        menu.addItem(startingItem)

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
        let hasLayer = running && currentLayer != "?"
        startingItem?.isHidden = !running || hasLayer
        layerItem?.title = String(format: NSLocalizedString("menu.layer", comment: ""), currentLayer)
        layerItem?.isHidden = !hasLayer
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
