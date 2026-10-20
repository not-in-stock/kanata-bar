import Foundation
import TOMLDecoder
import Shared

struct KanataConfig: Codable {
    var path: String
    var config: String
    var port: UInt16
    var extraArgs: [String]

    enum CodingKeys: String, CodingKey {
        case path, config, port
        case extraArgs = "extra_args"
    }

    static let `default` = KanataConfig(
        path: "",
        config: "~/.config/kanata/kanata.kbd",
        port: 5829,
        extraArgs: []
    )

    init(path: String, config: String, port: UInt16, extraArgs: [String]) {
        self.path = path
        self.config = config
        self.port = port
        self.extraArgs = extraArgs
    }

    init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? d.path
        config = (try? c.decode(String.self, forKey: .config)) ?? d.config
        port = (try? c.decode(UInt16.self, forKey: .port)) ?? d.port
        extraArgs = (try? c.decode([String].self, forKey: .extraArgs)) ?? d.extraArgs
    }
}

struct KanataBarConfig: Codable {
    var autostartKanata: Bool
    var autorestartKanata: Bool
    var pamTouchid: String  // "false" or "auto"
    var launcher: String  // "auto" (sudo/authexec) or "helper" (experimental supervisor)
    var iconsDir: String?
    var iconTransition: IconTransition?
    var hudGeometry: String  // "auto", "ansi" or "iso"

    enum CodingKeys: String, CodingKey {
        case autostartKanata = "autostart_kanata"
        case autorestartKanata = "autorestart_kanata"
        case pamTouchid = "pam_touchid"
        case launcher = "launcher"
        case iconsDir = "icons_dir"
        case iconTransition = "icon_transition"
        case hudGeometry = "hud_geometry"
    }

    static let `default` = KanataBarConfig(
        autostartKanata: false,
        autorestartKanata: false,
        pamTouchid: "auto",
        launcher: "auto",
        iconsDir: nil,
        iconTransition: nil,
        hudGeometry: "auto"
    )

    init(autostartKanata: Bool, autorestartKanata: Bool, pamTouchid: String, launcher: String, iconsDir: String?,
         iconTransition: IconTransition?, hudGeometry: String = "auto") {
        self.autostartKanata = autostartKanata
        self.autorestartKanata = autorestartKanata
        self.pamTouchid = pamTouchid
        self.launcher = launcher
        self.iconsDir = iconsDir
        self.iconTransition = iconTransition
        self.hudGeometry = hudGeometry
    }

    init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autostartKanata = (try? c.decode(Bool.self, forKey: .autostartKanata)) ?? d.autostartKanata
        autorestartKanata = (try? c.decode(Bool.self, forKey: .autorestartKanata)) ?? d.autorestartKanata
        pamTouchid = (try? c.decode(String.self, forKey: .pamTouchid)) ?? d.pamTouchid
        launcher = (try? c.decode(String.self, forKey: .launcher)) ?? d.launcher
        iconsDir = try? c.decode(String.self, forKey: .iconsDir)
        iconTransition = try? c.decode(IconTransition.self, forKey: .iconTransition)
        hudGeometry = (try? c.decode(String.self, forKey: .hudGeometry)) ?? d.hudGeometry
    }

    /// Explicit HUD geometry from config, or nil for auto-detection.
    var hudGeometryKind: KeyboardLayoutKind? {
        KeyboardLayoutKind(rawValue: hudGeometry.lowercased())
    }
}

struct Config: Codable {
    var kanata: KanataConfig
    var kanataBar: KanataBarConfig

    enum CodingKeys: String, CodingKey {
        case kanata
        case kanataBar = "kanata_bar"
    }

    static let `default` = Config(
        kanata: .default,
        kanataBar: .default
    )

    init(kanata: KanataConfig, kanataBar: KanataBarConfig) {
        self.kanata = kanata
        self.kanataBar = kanataBar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kanata = (try? c.decode(KanataConfig.self, forKey: .kanata)) ?? .default
        kanataBar = (try? c.decode(KanataBarConfig.self, forKey: .kanataBar)) ?? .default
    }

    // MARK: - Load

    static func load(from explicitPath: String?) -> Config {
        let path: String
        if let explicitPath {
            path = expandTilde(explicitPath)
        } else {
            let defaultPath = "\(NSHomeDirectory())/\(Constants.configDir)/\(Constants.configFilename)"
            guard FileManager.default.fileExists(atPath: defaultPath) else {
                return .default
            }
            path = defaultPath
        }

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("warning: could not read config file: \(path)")
            return .default
        }

        return decode(contents)
    }

    static func decode(_ toml: String) -> Config {
        guard let data = toml.data(using: .utf8),
              var config = try? TOMLDecoder().decode(Config.self, from: data) else {
            return .default
        }

        config.kanata.config = expandTilde(config.kanata.config)
        if let dir = config.kanataBar.iconsDir {
            config.kanataBar.iconsDir = expandTilde(dir)
        }

        return config
    }

    static func resolvePamTouchid(_ value: String) -> Bool {
        guard value == "auto" else { return false }
        for path in ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"] {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Path Utilities

    static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst())
        }
        return path
    }

    /// Probed when `path` is empty and `which` finds nothing. GUI apps inherit
    /// launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains no package
    /// manager directories. Ordered by installation popularity.
    static let kanataSearchDirs = [
        "/opt/homebrew/bin",                          // brew (Apple Silicon)
        "/usr/local/bin",                             // brew (Intel) / manual installs
        "/run/current-system/sw/bin",                 // nix-darwin system profile
        "/etc/profiles/per-user/\(NSUserName())/bin", // nix-darwin user profile
        "~/.nix-profile/bin",                         // standalone nix
    ]

    static func resolveKanataPath(_ path: String) -> String {
        guard path.isEmpty else { return expandTilde(path) }
        if let found = whichKanata() { return found }
        return searchKanata(in: kanataSearchDirs, isAccessible: isBinaryAccessible)
    }

    /// Returns the first accessible `<dir>/kanata`, or the bare binary name as
    /// the "unresolved" sentinel (`isBinaryAccessible` reports it not found).
    static func searchKanata(in dirs: [String], isAccessible: (String) -> Bool) -> String {
        for dir in dirs {
            let candidate = expandTilde(dir) + "/" + Constants.kanataBinaryName
            if isAccessible(candidate) { return candidate }
        }
        return Constants.kanataBinaryName
    }

    private static func whichKanata() -> String? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [Constants.kanataBinaryName]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    static func isBinaryAccessible(_ path: String) -> Bool {
        guard path != Constants.kanataBinaryName else { return false }  // unresolved bare name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
