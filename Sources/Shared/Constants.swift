import Foundation

public enum Constants {
    public static let bundleID = "com.kanata-bar"
    public static let helperBundleID = "com.kanata-bar.helper"
    public static let helperPlistName = "com.kanata-bar.helper.plist"

    public static let defaultPort: UInt16 = 5829
    public static let defaultHost = "127.0.0.1"
    public static let configDir = ".config/kanata-bar"
    public static let configFilename = "config.toml"

    public enum CLI {
        public static let installAgent = "--install-agent"
        public static let uninstallAgent = "--uninstall-agent"
        public static let noAutostart = "--no-autostart"
        public static let iconsDir = "--icons-dir"
        public static let port = "--port"
        public static let kanata = "--kanata"
        public static let config = "--config"
        public static let configFile = "--config-file"
    }

    public enum Log {
        public static let appFilename = "kanata-bar.log"
        public static let kanataFilename = "kanata.log"
    }
}
