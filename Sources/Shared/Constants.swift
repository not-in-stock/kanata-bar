import Foundation

public enum Constants {
    public static let bundleID = "com.kanata-bar"
    public static let helperBundleID = "com.kanata-bar.helper"
    public static let helperPlistName = "com.kanata-bar.helper.plist"

    public static let kanataBinaryName = "kanata"
    public static let defaultPort: UInt16 = 5829
    public static let defaultHost = "127.0.0.1"
    public static let configDir = ".config/kanata-bar"
    public static let configFilename = "config.toml"

    /// The privileged no-args supervisor binary (task 18 / option 2b). Shipped in
    /// the app bundle's `Contents/MacOS/`; pinned by a sudo `sha256:` digest rule.
    public static let superviseBinaryName = "kanata-bar-supervise"
    /// Root-owned launch spec the supervisor reads (what to run). Written by the
    /// nix module; its existence is the signal that the digest-pinned NOPASSWD
    /// path is configured. See the wiki `reference/sudoers-digest-pinning`.
    public static let superviseSpecPath = "/etc/kanata-bar/supervise.env"

    /// The user-owned stop sentinel the root launcher polls; deleting it reaps
    /// kanata with no second privileged call. The formula lives here so the app
    /// (`StopSentinel`) and the root supervisor can never derive different paths.
    public static func stopSentinelPath(home: String) -> String {
        home + "/Library/Caches/com.kanata-bar/kanata-stop.sentinel"
    }

    public enum CLI {
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
