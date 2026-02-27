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
            container.setAccessibilityLabel("Kanata Bar")
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
        startingView.setAccessibilityLabel(NSLocalizedString("menu.starting", comment: ""))
        startingItem.view = startingView
        menu.addItem(startingItem)

        layerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        layerItem.isEnabled = false
        let rollerView = LayerRollerView(prefix: NSLocalizedString("menu.layer.prefix", comment: ""))
        layerItem.view = rollerView
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
        switch appState {
        case .stopped:
            startingItem?.isHidden = true
            layerItem?.isHidden = true
            startItem?.isHidden = false
            startItem?.isEnabled = true
            stopItem?.isHidden = true
            reloadItem?.isHidden = true

        case .starting:
            startingItem?.isHidden = false
            layerItem?.isHidden = true
            startItem?.isHidden = true
            stopItem?.isHidden = false
            stopItem?.isEnabled = true
            reloadItem?.isHidden = true

        case .running(let layer):
            startingItem?.isHidden = true
            (layerItem?.view as? LayerRollerView)?.update(layer: layer, animated: true)
            layerItem?.isHidden = false
            startItem?.isHidden = true
            stopItem?.isHidden = false
            stopItem?.isEnabled = true
            reloadItem?.isHidden = false
            reloadItem?.isEnabled = true

        case .restarting:
            startingItem?.isHidden = true
            layerItem?.isHidden = true
            startItem?.isHidden = true
            stopItem?.isHidden = false
            stopItem?.isEnabled = true
            reloadItem?.isHidden = true
        }
    }

    // MARK: - Actions

    @objc func doStart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        restartTimestamps.removeAll()
        log("starting kanata: \(kanataProcess.binaryPath) -c \(kanataProcess.configPath) --port \(kanataProcess.port)")
        appState = .starting
        kanataProcess.start()
    }

    @objc func doStop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        kanataProcess.stop()
        appState = .stopped
    }

    @objc func doReload() {
        kanataClient.sendReload()
    }

    @objc func doQuit() {
        NSApplication.shared.terminate(nil)
    }
}
