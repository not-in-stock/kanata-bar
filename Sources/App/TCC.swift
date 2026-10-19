import Foundation
import Shared

extension AppDelegate {
    /// Reset TCC permissions when the app binary or install location changes.
    /// This ensures macOS re-prompts for Input Monitoring after updates.
    func resetTCCIfSourceChanged() {
        let currentSource = installFingerprint()
        let previousSource = UserDefaults.standard.string(forKey: "installSource")

        if let previous = previousSource, previous != currentSource {
            Logging.log("install source changed (\(previous) → \(currentSource)), resetting TCC")
            let bundleID = Bundle.main.bundleIdentifier ?? Constants.bundleID
            // Reset the Accessibility grant: its csreq is pinned to the *old* cdhash, so
            // after a rebuild/move the toggle may still show ON while `AXIsProcessTrusted()`
            // returns false, and toggling off/on won't fix it — you'd have to remove+re-add
            // the row by hand. Deleting it makes the next request a clean re-grant. See the
            // TCC-regrant gotcha. (Input Monitoring is no longer requested — Accessibility
            // covers input capture on modern macOS.)
            let tccutil = Process()
            tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccutil.arguments = ["reset", "Accessibility", bundleID]
            try? tccutil.run()
            tccutil.waitUntilExit()
        }

        UserDefaults.standard.set(currentSource, forKey: "installSource")
    }

    // MARK: - Private Helpers

    /// Returns a string that changes whenever the app binary or install location changes.
    /// Combines resolved bundle path with the executable's CDHash (which is what macOS TCC validates).
    /// Also used by helper registration to detect an install-source switch that
    /// leaves a stale SMAppService record (see `registerHelperIfNeeded`).
    func installFingerprint() -> String {
        let path = resolvedBundlePath()
        let cdHash = executableCDHash() ?? "unknown"
        return "\(path)|\(cdHash)"
    }

    private func executableCDHash() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dvvv", Bundle.main.bundlePath]
        let pipe = Pipe()
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        // Extract "CDHash=<hex>" line
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CDHash=") {
                return String(trimmed.dropFirst("CDHash=".count))
            }
        }
        return nil
    }

    private func resolvedBundlePath() -> String {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        return url.resolvingSymlinksInPath().path
    }
}
