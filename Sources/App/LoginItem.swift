import Foundation
import ServiceManagement
import Shared

private let loginItemService = SMAppService.mainApp

extension AppDelegate {
    var isLoginItemEnabled: Bool {
        loginItemService.status == .enabled
    }

    /// External LaunchAgent (nix-darwin symlink or brew service) detected.
    var isAgentExternal: Bool {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(Constants.bundleID).plist"
        guard FileManager.default.fileExists(atPath: plistPath) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: plistPath)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func enableLoginItem() {
        do {
            try loginItemService.register()
            log("login item registered (status: \(loginItemService.status))")
        } catch {
            log("ERROR: login item register failed: \(error)")
        }
    }

    func disableLoginItem() {
        do {
            try loginItemService.unregister()
            log("login item unregistered (status: \(loginItemService.status))")
        } catch {
            log("ERROR: login item unregister failed: \(error)")
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
        let oldPlist = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(Constants.bundleID).plist"
        guard FileManager.default.fileExists(atPath: oldPlist) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: oldPlist)
        let isSymlink = attrs?[.type] as? FileAttributeType == .typeSymbolicLink
        guard !isSymlink else { return }
        try? FileManager.default.removeItem(atPath: oldPlist)
    }
}
