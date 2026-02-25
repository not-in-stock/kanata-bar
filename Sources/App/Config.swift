import Foundation

struct Config {
    var kanata: String
    var config: String
    var port: UInt16
    var iconsDir: String?
    var autostart: Bool
    var autorestart: Bool
    var extraArgs: [String]

    static let `default` = Config(
        kanata: "",
        config: "~/.config/kanata/kanata.kbd",
        port: 5829,
        iconsDir: nil,
        autostart: true,
        autorestart: false,
        extraArgs: []
    )

    // MARK: - Load

    static func load(from explicitPath: String?) -> Config {
        var config = Config.default

        let path: String
        if let explicitPath {
            path = expandTilde(explicitPath)
        } else {
            let defaultPath = "\(NSHomeDirectory())/\(Constants.configDir)/\(Constants.configFilename)"
            guard FileManager.default.fileExists(atPath: defaultPath) else {
                return config
            }
            path = defaultPath
        }

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("warning: could not read config file: \(path)")
            return config
        }

        let values = TOMLParser.parse(contents)

        if let v = values["kanata"] as? String { config.kanata = v }
        if let v = values["config"] as? String { config.config = v }
        if let v = values["port"] as? Int, let p = UInt16(exactly: v) { config.port = p }
        if let v = values["icons_dir"] as? String { config.iconsDir = v }
        if let v = values["autostart"] as? Bool { config.autostart = v }
        if let v = values["autorestart"] as? Bool { config.autorestart = v }
        if let v = values["extra_args"] as? [String] { config.extraArgs = v }

        return config
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
