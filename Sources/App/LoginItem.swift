import Foundation
import ServiceManagement
import Shared

private let loginItemService = SMAppService.mainApp

extension AppDelegate {
    var isLoginItemEnabled: Bool {
        loginItemService.status == .enabled
    }

    /// External LaunchAgent detected — autostart is managed by something other than this app
    /// (e.g. nix-darwin, brew, or SMAppService wrapper).
    var isAgentExternal: Bool {
        if hasPlistSymlink() { return true }

        // Only check launchctl when the app hasn't registered itself via SMAppService —
        // if isLoginItemEnabled is true, "com.kanata-bar" in launchctl is our own registration.
        if !isLoginItemEnabled {
            return !findExternalLaunchdLabels(excludeOwn: false).isEmpty
        }

        return false
    }

    /// If an external agent manages autostart, disable our own SMAppService registration
    /// to avoid launching two instances at login.
    func resolveLoginItemConflict() {
        guard isLoginItemEnabled else { return }

        // Check even when isLoginItemEnabled is true — exclude our own exact label
        // to distinguish external wrappers from our own SMAppService registration.
        let hasExternal = hasPlistSymlink()
            || !findExternalLaunchdLabels(excludeOwn: true).isEmpty

        if hasExternal {
            Logging.log("external agent detected, disabling own login item to avoid conflict")
            disableLoginItem()
        }
    }

    func enableLoginItem() {
        do {
            try loginItemService.register()
            Logging.log("login item registered (status: \(loginItemService.status))")
        } catch {
            Logging.log("ERROR: login item register failed: \(error)")
        }
    }

    func disableLoginItem() {
        do {
            try loginItemService.unregister()
            Logging.log("login item unregistered (status: \(loginItemService.status))")
        } catch {
            Logging.log("ERROR: login item unregister failed: \(error)")
        }
    }

    @objc func doToggleAgent() {
        guard !isAgentExternal else { return }
        if isLoginItemEnabled {
            disableLoginItem()
        } else {
            enableLoginItem()
        }
        updateStartAtLoginState()
        updateMenuState()
    }

    /// Remove stale LaunchAgent plist from previous versions.
    /// Only removes regular files (ours), not symlinks (nix-darwin/brew).
    func migrateFromLaunchAgent() {
        let path = plistPath()
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard !isSymlink(atPath: path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private Helpers

    private func plistPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(Constants.bundleID).plist"
    }

    /// Check for a symlinked plist in ~/Library/LaunchAgents/ (legacy brew/nix-darwin).
    private func hasPlistSymlink() -> Bool {
        let path = plistPath()
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return isSymlink(atPath: path)
    }

    private func isSymlink(atPath path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Find launchd labels containing our bundle ID, excluding `application.*` entries.
    /// When `excludeOwn` is true, also excludes our exact bundle ID label.
    private func findExternalLaunchdLabels(excludeOwn: Bool) -> [String] {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["list"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard let _ = try? proc.run() else { return [] }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [String] = []
        for line in output.components(separatedBy: "\n") {
            let label = line.components(separatedBy: "\t").last ?? ""
            if label.hasPrefix("application.") { continue }
            if !label.contains(Constants.bundleID) { continue }
            if excludeOwn && label == Constants.bundleID { continue }
            results.append(label)
        }
        return results
    }
}
