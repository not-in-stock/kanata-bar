import Foundation
import TOMLDecoder
import Shared

struct Config: Codable {
    var kanata: String
    var config: String
    var port: UInt16
    var iconsDir: String?
    var autostart: Bool
    var autorestart: Bool
    var extraArgs: [String]
    var pamTid: String  // "false" or "auto"
    var iconTransition: IconTransition?

    enum CodingKeys: String, CodingKey {
        case kanata, config, port
        case iconsDir = "icons_dir"
        case autostart, autorestart
        case extraArgs = "extra_args"
        case pamTid = "pam_tid"
        case iconTransition = "icon_transition"
    }

    static let `default` = Config(
        kanata: "",
        config: "~/.config/kanata/kanata.kbd",
        port: 5829,
        iconsDir: nil,
        autostart: true,
        autorestart: false,
        extraArgs: [],
        pamTid: "false",
        iconTransition: nil
    )

    init(kanata: String, config: String, port: UInt16, iconsDir: String?,
         autostart: Bool, autorestart: Bool, extraArgs: [String],
         pamTid: String, iconTransition: IconTransition?) {
        self.kanata = kanata
        self.config = config
        self.port = port
        self.iconsDir = iconsDir
        self.autostart = autostart
        self.autorestart = autorestart
        self.extraArgs = extraArgs
        self.pamTid = pamTid
        self.iconTransition = iconTransition
    }

    init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kanata = (try? c.decode(String.self, forKey: .kanata)) ?? d.kanata
        config = (try? c.decode(String.self, forKey: .config)) ?? d.config
        port = (try? c.decode(UInt16.self, forKey: .port)) ?? d.port
        iconsDir = try? c.decode(String.self, forKey: .iconsDir)
        autostart = (try? c.decode(Bool.self, forKey: .autostart)) ?? d.autostart
        autorestart = (try? c.decode(Bool.self, forKey: .autorestart)) ?? d.autorestart
        extraArgs = (try? c.decode([String].self, forKey: .extraArgs)) ?? d.extraArgs
        pamTid = (try? c.decode(String.self, forKey: .pamTid)) ?? d.pamTid
        iconTransition = try? c.decode(IconTransition.self, forKey: .iconTransition)
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

        config.config = expandTilde(config.config)
        if let dir = config.iconsDir {
            config.iconsDir = expandTilde(dir)
        }

        return config
    }

    static func resolvePamTid(_ value: String) -> Bool {
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

    static func resolveKanataPath(_ path: String) -> String {
        if path.isEmpty {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["kanata"]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            try? which.run()
            which.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output.isEmpty ? "kanata" : output
        }
        return expandTilde(path)
    }

    static func isBinaryAccessible(_ path: String) -> Bool {
        guard path != "kanata" else { return false }  // unresolved bare name
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
