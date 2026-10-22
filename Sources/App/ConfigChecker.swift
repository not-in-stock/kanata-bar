import Foundation

/// Validates a kanata config by running `kanata --check -c <path>` and
/// condensing its diagnostic into one line.
///
/// kanata prints colourised log lines even without a TTY; the error diagnostic
/// is a multi-line miette report on stderr with a `╭─[file:line:col]` location
/// and a `help:` line that carries the actual message.
struct ConfigChecker: Sendable {

    enum Outcome: Equatable, Sendable {
        case valid
        /// `summary` is one line for a tooltip; `details` the full stripped output for the log.
        case invalid(summary: String, details: String)
        /// The checker itself could not run (binary missing, timeout…).
        case failed(String)
    }

    let binaryPath: String

    /// Runs the check off the caller's actor.
    func check(configPath: String) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            Self.run(binaryPath: binaryPath, configPath: configPath)
        }.value
    }

    private static func run(binaryPath: String, configPath: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--check", "-c", configPath]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return .failed("cannot run \(binaryPath): \(error.localizedDescription)")
        }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Timing.configCheckTimeout, execute: deadline)
        // Drain both pipes before waiting so a chatty check cannot block on a full pipe.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let timedOut = !deadline.isCancelled && process.terminationReason == .uncaughtSignal
        deadline.cancel()
        if timedOut { return .failed("kanata --check did not finish in \(Int(Timing.configCheckTimeout)) s") }

        let text = stripANSI(String(bytes: stderr, encoding: .utf8) ?? "")
            + "\n" + stripANSI(String(bytes: stdout, encoding: .utf8) ?? "")
        if process.terminationStatus == 0 { return .valid }
        return .invalid(summary: summarize(text), details: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Parsing

    /// One-line summary of a kanata diagnostic: `file:line:col: message`.
    static func summarize(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let location = lines.lazy.compactMap(locationIn).first
        let help = lines.lazy.compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("help:") ? String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) : nil
        }.first
        let errorLine = lines.lazy.compactMap { line -> String? in
            guard let r = line.range(of: "[ERROR]") else { return nil }
            let t = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }.first
        let message = help ?? errorLine ?? "invalid config"
        return [location, message].compactMap { $0 }.joined(separator: ": ")
    }

    /// `   ╭─[/path/to/kanata.kbd:12:3]` → `kanata.kbd:12:3` (file name only: the
    /// full path is noise in a tooltip, and includes make the name meaningful).
    private static func locationIn(_ line: String) -> String? {
        guard let open = line.range(of: "╭─["), let close = line[open.upperBound...].firstIndex(of: "]") else { return nil }
        let loc = String(line[open.upperBound..<close])
        guard let slash = loc.lastIndex(of: "/") else { return loc }
        return String(loc[loc.index(after: slash)...])
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
