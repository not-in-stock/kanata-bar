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
        // Check 1: symlink in ~/Library/LaunchAgents/ (legacy brew service)
        let plistPath = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(Constants.bundleID).plist"
        if FileManager.default.fileExists(atPath: plistPath) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: plistPath)
            if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
                return true
            }
        }

        // Check 2: a launchd agent with a label containing our bundle ID is registered,
        // but this app did not register itself via SMAppService. This covers:
        // - nix-darwin legacy launchd (label "com.kanata-bar", loaded via launchctl)
        // - darwin-smapp wrapper (label "com.kanata-bar.agent", registered via SMAppService)
        if !isLoginItemEnabled {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["list"]
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    for line in output.components(separatedBy: "\n") {
                        let label = line.components(separatedBy: "\t").last ?? ""
                        if label.contains(Constants.bundleID) {
                            return true
                        }
                    }
                }
            } catch {}
        }

        return false
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
        let oldPlist = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents/\(Constants.bundleID).plist"
        guard FileManager.default.fileExists(atPath: oldPlist) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: oldPlist)
        let isSymlink = attrs?[.type] as? FileAttributeType == .typeSymbolicLink
        guard !isSymlink else { return }
        try? FileManager.default.removeItem(atPath: oldPlist)
    }
}
