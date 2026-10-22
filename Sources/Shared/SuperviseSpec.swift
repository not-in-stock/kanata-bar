import Foundation

/// The root-owned launch spec the privileged supervisor reads to decide *what to
/// run* (task 18 / option 2b). This is the privilege boundary: the digest-pinned
/// supervisor execs only what this file — written by root (the nix module) — says,
/// so an unprivileged process can't redirect root to an arbitrary binary.
///
/// Format is `KEY=value`, one per line; blank lines and `#` comments ignored; a
/// value may be wrapped in matching single/double quotes. `KANATA_EXTRA_ARGS` is
/// split on spaces (the spec is root-controlled, so no shell-quoting is needed —
/// args must not themselves contain spaces).
public struct SuperviseSpec: Equatable, Sendable {
    public let kanataBin: String
    public let configPath: String
    public let port: UInt16
    public let extraArgs: [String]
    public let logPath: String?

    public enum ParseError: Error, Equatable {
        case missing(String)
        case invalidPort(String)
    }

    public init(kanataBin: String, configPath: String, port: UInt16, extraArgs: [String], logPath: String?) {
        self.kanataBin = kanataBin
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.logPath = logPath
    }

    public static func parse(_ contents: String) throws -> SuperviseSpec {
        var kv: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            kv[key] = val
        }

        guard let bin = kv["KANATA_BIN"], !bin.isEmpty else { throw ParseError.missing("KANATA_BIN") }
        guard let cfg = kv["KANATA_CONFIG"], !cfg.isEmpty else { throw ParseError.missing("KANATA_CONFIG") }
        guard let portStr = kv["KANATA_PORT"], !portStr.isEmpty else { throw ParseError.missing("KANATA_PORT") }
        guard let port = UInt16(portStr) else { throw ParseError.invalidPort(portStr) }

        let extra = (kv["KANATA_EXTRA_ARGS"] ?? "")
            .split(separator: " ")
            .map(String.init)
        let log = kv["KANATA_LOG"].flatMap { $0.isEmpty ? nil : $0 }

        return SuperviseSpec(kanataBin: bin, configPath: cfg, port: port, extraArgs: extra, logPath: log)
    }

    /// Arguments passed to the kanata binary (argv[0] excluded — that's `kanataBin`).
    public func kanataArguments() -> [String] {
        ["-c", configPath, "--port", "\(port)"] + extraArgs
    }
}
