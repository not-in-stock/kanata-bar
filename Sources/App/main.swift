import AppKit

// Handle --install-agent / --uninstall-agent before starting the app
let cliArgs = CommandLine.arguments
if cliArgs.contains("--install-agent") {
    let helper = AppDelegate()
    helper.installAgent()
    print("LaunchAgent installed at \(helper.launchAgentPath)")
    exit(0)
} else if cliArgs.contains("--uninstall-agent") {
    let helper = AppDelegate()
    helper.uninstallAgent()
    print("LaunchAgent removed from \(helper.launchAgentPath)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
