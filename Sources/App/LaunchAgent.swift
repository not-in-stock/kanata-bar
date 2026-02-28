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
        if isAgentInstalled {
            uninstallAgent()
        } else {
            installAgent()
        }
        startAtLoginItem?.state = isAgentInstalled ? .on : .off
        updateMenuState()
    }

    func buildLaunchAgentPlist() -> String {
        let skip: Set<String> = [Constants.CLI.installAgent, Constants.CLI.uninstallAgent, Constants.CLI.noAutostart, "--"]
        let args = CommandLine.arguments.filter { !skip.contains($0) }

        let binary: String
        let arg0 = args[0]
        if arg0.hasPrefix("/") {
            binary = arg0
        } else {
            let cwd = FileManager.default.currentDirectoryPath
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
            <string>\(Self.agentLabel)</string>
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
