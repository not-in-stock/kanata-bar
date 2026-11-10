import ApplicationServices
import Shared

extension AppDelegate {
    /// kanata exited immediately without ever getting a PID. Config (`--check`) and
    /// the binary path are gated elsewhere, so this shape is almost always a
    /// permission denial — we lead on the failure *shape*, and only consult the log to
    /// carve out the port-in-use exception. That keeps a reworded kanata log from
    /// silently regressing us to a generic "stopped" notice.
    func handleEarlyExit(exitCode: Int32) {
        Logging.log("kanata exited immediately (exit code \(exitCode))")
        switch KanataFailure.classify(logPath: Logging.kanataLogURL.path) {
        case .portInUse:
            appState = .stopped
            Notifications.sendCrash()
        case .permissionDenied, .unknown:
            handlePermissionFailure()
        }
    }

    /// kanata exited reporting a permission failure. It names Input Monitoring first
    /// even when the real gap is Accessibility (its first gate), so we always steer to
    /// Accessibility — the only grant kanata-bar drives. When `AXIsProcessTrusted()` is
    /// *true* here, the grant exists but its csreq is stale (the app was rebuilt/moved
    /// → new cdhash) and the HID layer rejects it, so delete it and re-request from this
    /// user session to write a fresh csreq. See the wiki gotcha
    /// "stale-accessibility-csreq-looks-like-im-denied".
    func handlePermissionFailure() {
        appState = .stopped
        if TCCPermissions.isGranted(.accessibility) {
            Logging.log("kanata denied device access while AXIsProcessTrusted()==true → stale Accessibility csreq")
            if !didAutoHealPermissions {
                didAutoHealPermissions = true
                resetAccessibilityGrant()
                TCCPermissions.request(.accessibility) // re-add with the current cdhash
            }
            Notifications.sendPermissionStale()
        } else {
            Logging.log("kanata denied device access; Accessibility not granted")
            TCCPermissions.request(.accessibility)
            Notifications.sendPermissionsNeeded()
        }
        TCCPermissions.openSettings(for: .accessibility)
    }
}
