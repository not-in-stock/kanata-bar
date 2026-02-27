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

    enum CodingKeys: String, CodingKey {
        case kanata, config, port
        case iconsDir = "icons_dir"
        case autostart, autorestart
        case extraArgs = "extra_args"
        case pamTid = "pam_tid"
    }

    static let `default` = Config(
        kanata: "",
        config: "~/.config/kanata/kanata.kbd",
        port: 5829,
        iconsDir: nil,
        autostart: true,
        autorestart: false,
        extraArgs: [],
        pamTid: "false"
    )

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
        var config = Config.default

        guard let data = toml.data(using: .utf8) else { return config }

        do {
            let decoded = try TOMLDecoder().decode(Config.self, from: data)
            config = decoded
        } catch {
            // Partial decode: try each field individually from a loose dictionary
            if let partial = try? TOMLDecoder().decode(PartialConfig.self, from: data) {
                if let v = partial.kanata { config.kanata = v }
                if let v = partial.config { config.config = v }
                if let v = partial.port { config.port = v }
                if let v = partial.iconsDir { config.iconsDir = v }
                if let v = partial.autostart { config.autostart = v }
                if let v = partial.autorestart { config.autorestart = v }
                if let v = partial.extraArgs { config.extraArgs = v }
                if let v = partial.pamTid { config.pamTid = v }
            }
        }

        // Expand ~ in paths
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
}

/// All-optional mirror of Config for partial TOML files (missing keys → nil).
private struct PartialConfig: Codable {
    var kanata: String?
    var config: String?
    var port: UInt16?
    var iconsDir: String?
    var autostart: Bool?
    var autorestart: Bool?
    var extraArgs: [String]?
    var pamTid: String?

    enum CodingKeys: String, CodingKey {
        case kanata, config, port
        case iconsDir = "icons_dir"
        case autostart, autorestart
        case extraArgs = "extra_args"
        case pamTid = "pam_tid"
    }
}
