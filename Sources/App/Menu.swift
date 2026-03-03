import AppKit

extension AppDelegate {
    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addHeader(to: menu)
        addStatusItems(to: menu)
        menu.addItem(NSMenuItem.separator())
        addKanataControls(to: menu)
        menu.addItem(NSMenuItem.separator())
        addSettings(to: menu)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(doQuit), keyEquivalent: "q"))

        statusItem.menu = menu
        updateMenuState()
    }

    private func addHeader(to menu: NSMenu) {
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
            container.setAccessibilityElement(true)
            container.setAccessibilityRole(.staticText)
            container.setAccessibilityLabel("Kanata Bar")
            container.setAccessibilityChildren([])
            headerItem.view = container
        }
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
    }

    private func addStatusItems(to menu: NSMenu) {
        startingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        startingItem.isEnabled = false
        let startingView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        startingLabel = NSTextField(labelWithString: NSLocalizedString("menu.starting", comment: ""))
        startingLabel.font = NSFont.menuFont(ofSize: 14)
        startingLabel.textColor = .secondaryLabelColor
        startingLabel.translatesAutoresizingMaskIntoConstraints = false
        startingView.addSubview(spinner)
        startingView.addSubview(startingLabel)
        startingLeading = startingLabel.leadingAnchor.constraint(equalTo: startingView.leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            startingLeading,
            startingLabel.centerYAnchor.constraint(equalTo: startingView.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: startingView.trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: startingView.centerYAnchor),
        ])
        startingView.setAccessibilityElement(true)
        startingView.setAccessibilityRole(.staticText)
        startingView.setAccessibilityLabel(NSLocalizedString("accessibility.starting", comment: ""))
        startingView.setAccessibilityChildren([])
        startingItem.view = startingView
        menu.addItem(startingItem)

        layerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        layerItem.isEnabled = false
        let rollerView = LayerRollerView(prefix: NSLocalizedString("menu.layer.prefix", comment: ""))
        layerItem.view = rollerView
        menu.addItem(layerItem)
    }

    private func addKanataControls(to menu: NSMenu) {
        let hasSection: Bool
        if #available(macOS 14.0, *) {
            kanataSectionItem = NSMenuItem.sectionHeader(title: NSLocalizedString("menu.section.kanata", comment: ""))
            menu.addItem(kanataSectionItem)
            hasSection = true
        } else {
            hasSection = false
        }

        let startTitle = hasSection ? NSLocalizedString("menu.start.short", comment: "") : NSLocalizedString("menu.start", comment: "")
        let stopTitle = hasSection ? NSLocalizedString("menu.stop.short", comment: "") : NSLocalizedString("menu.stop", comment: "")
        startItem = NSMenuItem(title: startTitle, action: #selector(doStart), keyEquivalent: "")
        stopItem = NSMenuItem(title: stopTitle, action: #selector(doStop), keyEquivalent: "")
        reloadItem = NSMenuItem(title: NSLocalizedString("menu.reload", comment: ""), action: #selector(doReload), keyEquivalent: "")
        if hasSection {
            startItem.setAccessibilityTitle(NSLocalizedString("menu.start", comment: ""))
            stopItem.setAccessibilityTitle(NSLocalizedString("menu.stop", comment: ""))
            reloadItem.setAccessibilityTitle(NSLocalizedString("accessibility.reload", comment: ""))
        }
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(reloadItem)
    }

    private func addSettings(to menu: NSMenu) {
        startAtLoginItem = NSMenuItem(title: NSLocalizedString("menu.startAtLogin", comment: ""), action: #selector(doToggleAgent), keyEquivalent: "")
        startAtLoginItem.setAccessibilityTitle(NSLocalizedString("accessibility.startAtLogin", comment: ""))
        updateStartAtLoginState()
        menu.addItem(startAtLoginItem)

        let logsItem = NSMenuItem(title: NSLocalizedString("menu.logs", comment: ""), action: nil, keyEquivalent: "")
        let logsSubmenu = NSMenu()
        logsSubmenu.addItem(NSMenuItem(title: NSLocalizedString("menu.logs.app", comment: ""), action: #selector(doViewAppLog), keyEquivalent: ""))
        kanataLogsItem = NSMenuItem(title: NSLocalizedString("menu.logs.kanata", comment: ""), action: #selector(doViewKanataLog), keyEquivalent: "")
        logsSubmenu.addItem(kanataLogsItem)
        logsItem.submenu = logsSubmenu
        menu.addItem(logsItem)
    }

    func updateMenuState() {
        if #available(macOS 14.0, *) {
            reloadItem?.badge = isExternal ? NSMenuItemBadge(string: NSLocalizedString("menu.external", comment: "")) : nil
        }
        if isExternal && externalPID > 0 {
            reloadItem?.toolTip = "PID \(externalPID)"
        } else {
            reloadItem?.toolTip = nil
        }
        kanataLogsItem?.isHidden = isExternal
        updateStartAtLoginState()

        // Align custom views with standard menu items.
        // When any item has a checkmark, macOS adds ~11px for the check column.
        let hasCheck = startAtLoginItem?.state == .on
        let leading: CGFloat = hasCheck ? 25 : 14
        startingLeading?.constant = leading
        (layerItem?.view as? LayerRollerView)?.updateLeading(leading)

        switch appState {
        case .stopped:
            startingItem?.isHidden = true
            layerItem?.isHidden = true
            startItem?.isHidden = false
            startItem?.isEnabled = true
            stopItem?.isHidden = true
            reloadItem?.isHidden = true

        case .starting:
            let startingText = NSLocalizedString(
                isExternal ? "menu.connecting" : "menu.starting", comment: "")
            startingLabel?.stringValue = startingText
            let a11yText = NSLocalizedString(
                isExternal ? "accessibility.connecting" : "accessibility.starting", comment: "")
            startingItem?.view?.setAccessibilityLabel(a11yText)
            startingItem?.isHidden = false
            layerItem?.isHidden = true
            startItem?.isHidden = isExternal ? false : true
            startItem?.isEnabled = isExternal
            stopItem?.isHidden = isExternal
            stopItem?.isEnabled = !isExternal
            reloadItem?.isHidden = true

        case .running(let layer):
            startingItem?.isHidden = true
            let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            (layerItem?.view as? LayerRollerView)?.update(layer: layer, animated: animated)
            layerItem?.isHidden = false
            startItem?.isHidden = true
            stopItem?.isHidden = isExternal
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

    func updateStartAtLoginState() {
        if isAgentExternal {
            startAtLoginItem?.state = .on
            startAtLoginItem?.isEnabled = false
            if #available(macOS 14.0, *) {
                startAtLoginItem?.badge = NSMenuItemBadge(string: NSLocalizedString("menu.external", comment: ""))
            }
            startAtLoginItem?.toolTip = NSLocalizedString("menu.startAtLogin.external.tooltip", comment: "")
        } else {
            startAtLoginItem?.state = isAgentInstalled ? .on : .off
            startAtLoginItem?.isEnabled = true
            if #available(macOS 14.0, *) {
                startAtLoginItem?.badge = nil
            }
            startAtLoginItem?.toolTip = nil
        }
    }

    // MARK: - Actions

    @objc func doStart() {
        isExternal = false
        externalTimeoutWork?.cancel()
        externalTimeoutWork = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        restartTimestamps.removeAll()
        guard Config.isBinaryAccessible(kanataProcess.binaryPath) else {
            log("ERROR: kanata binary not found: \(kanataProcess.binaryPath)")
            Notifications.sendBinaryNotFound()
            return
        }
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
