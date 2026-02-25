import Foundation

enum Constants {
    static let bundleID = "com.kanata-bar"
    static let helperBundleID = "com.kanata-bar.helper"
    static let helperPlistName = "com.kanata-bar.helper.plist"

    static let defaultPort: UInt16 = 5829
    static let defaultHost = "127.0.0.1"
    static let configDir = ".config/kanata-bar"
    static let configFilename = "config.toml"

    enum CLI {
        static let installAgent = "--install-agent"
        static let uninstallAgent = "--uninstall-agent"
        static let noAutostart = "--no-autostart"
        static let iconsDir = "--icons-dir"
        static let port = "--port"
        static let kanata = "--kanata"
        static let config = "--config"
        static let configFile = "--config-file"
    }

    enum Log {
        static let appFilename = "kanata-bar.log"
        static let kanataFilename = "kanata.log"
    }
}
