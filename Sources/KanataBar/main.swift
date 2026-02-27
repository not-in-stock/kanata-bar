import AppKit
import KanataBarLib
import Shared

let cliArgs = CommandLine.arguments
if cliArgs.contains(Constants.CLI.installAgent) {
    let helper = AppDelegate()
    helper.installAgent()
    print("LaunchAgent installed at \(helper.launchAgentPath)")
    exit(0)
} else if cliArgs.contains(Constants.CLI.uninstallAgent) {
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
