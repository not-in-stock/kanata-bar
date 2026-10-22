import AppKit

// MARK: - Auto-reload on save (task 23)

extension AppDelegate {
    /// Builds the session-only auto-reloader and routes its status to the menu
    /// badge, the tray icon marker and the one-per-episode error notification.
    func setupAutoReloader(initiallyEnabled: Bool) {
        let reloader = AutoReloader.live(configPath: kanataProcess.configPath,
                                         binaryPath: kanataProcess.binaryPath,
                                         client: kanataClient)
        reloader.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.iconManager?.errorMarker = status.isError
            self.iconManager?.updateIcon(for: self.appState)
            self.updateMenuState()
        }
        reloader.onEnterError = { status in
            switch status {
            case .invalid(let summary):
                Notifications.sendAutoReloadError(body: summary)
            case .reloadFailed:
                Notifications.sendAutoReloadError(body: NSLocalizedString("notification.autoReload.failed.body", comment: ""))
            default:
                break
            }
        }
        autoReloader = reloader
        if initiallyEnabled { reloader.setEnabled(true) }
    }
}
