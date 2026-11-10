import UserNotifications
import Shared

@MainActor
enum Notifications {
    static func sendReload() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.reload.title", comment: "")
        content.body = NSLocalizedString("notification.reload.body", comment: "")

        let request = UNNotificationRequest(identifier: "kanata-reload", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Auto-reload could not apply the saved config; kanata keeps the previous one.
    /// Sent once per transition into the error state, not per failing save.
    static func sendAutoReloadError(body: String) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.autoReload.error.title", comment: "")
        content.body = body
        let request = UNNotificationRequest(identifier: "kanata-auto-reload-error", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendCrash() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.crash.title", comment: "")
        content.body = NSLocalizedString("notification.crash.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-crash", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendRestart() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.restart.title", comment: "")
        content.body = NSLocalizedString("notification.restart.body", comment: "")

        let request = UNNotificationRequest(identifier: "kanata-restart", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendAutorestartDisabled() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.restart.disabled.title", comment: "")
        content.body = NSLocalizedString("notification.restart.disabled.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-restart-disabled", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendStartFailure() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.startFailure.title", comment: "")
        content.body = NSLocalizedString("notification.startFailure.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-start-failure", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendPortConflict(port: UInt16) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.portConflict.title", comment: "")
        content.body = String(format: NSLocalizedString("notification.portConflict.body", comment: ""), "\(port)")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-port-conflict", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendPermissionsNeeded() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.permissionsNeeded.title", comment: "")
        content.body = NSLocalizedString("notification.permissionsNeeded.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-permissions-needed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// kanata was denied device access although the app believes Accessibility is
    /// granted — i.e. the grant's csreq went stale after a rebuild/move. The app has
    /// already reset + re-requested it; this tells the user to flip the toggle and
    /// relaunch so a fresh csreq takes effect.
    static func sendPermissionStale() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.permissionStale.title", comment: "")
        content.body = NSLocalizedString("notification.permissionStale.body", comment: "")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-permission-stale", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func sendBinaryNotFound() {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("notification.binaryNotFound.title", comment: "")
        let configPath = "~/\(Constants.configDir)/\(Constants.configFilename)"
        content.body = String(format: NSLocalizedString("notification.binaryNotFound.body", comment: ""), configPath)
        content.sound = .default

        let request = UNNotificationRequest(identifier: "kanata-binary-not-found", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
