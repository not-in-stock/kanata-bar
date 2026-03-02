import Foundation
import Shared

extension AppDelegate {
    static let agentLabel = Constants.bundleID
    static let agentPlistName = "\(agentLabel).plist"

    public var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(Self.agentPlistName)"
    }

    var isAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    /// Agent plist exists but is managed externally (e.g. nix-darwin, homebrew).
    var isAgentExternal: Bool {
        guard isAgentInstalled else { return false }
        // Fast path: symlink = definitely external
        let attrs = try? FileManager.default.attributesOfItem(atPath: launchAgentPath)
        if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
            return true
        }
        // Content mismatch = managed by something else
        guard let content = try? String(contentsOfFile: launchAgentPath, encoding: .utf8) else {
            return true
        }
        return content != buildLaunchAgentPlist()
    }

    public func installAgent() {
        let dir = (launchAgentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let plist = buildLaunchAgentPlist()
        do {
            try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to write LaunchAgent plist: \(error)")
        }
    }

    public func uninstallAgent() {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
    }

    @objc func doToggleAgent() {
        guard !isAgentExternal else { return }
        if isAgentInstalled {
            uninstallAgent()
        } else {
            installAgent()
        }
        updateStartAtLoginState()
        updateMenuState()
    }

    func buildLaunchAgentPlist() -> String {
        let skip: Set<String> = [Constants.CLI.installAgent, Constants.CLI.uninstallAgent, Constants.CLI.noAutostart, "--"]
        let args = CommandLine.arguments.filter { !skip.contains($0) }
        return Self.buildPlist(args: args, cwd: FileManager.default.currentDirectoryPath)
    }

    static func buildPlist(args: [String], cwd: String) -> String {
        let binary: String
        let arg0 = args[0]
        if arg0.hasPrefix("/") {
            binary = arg0
        } else {
            binary = "\(cwd)/\(arg0)"
        }

        var programArgs = "        <string>\(binary)</string>"
        for arg in args.dropFirst() {
            programArgs += "\n        <string>\(arg)</string>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(programArgs)
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }
}
