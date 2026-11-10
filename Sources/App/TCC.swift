import Foundation
import Shared

extension AppDelegate {
    /// Reset TCC permissions when the app binary or install location changes.
    /// This ensures macOS re-prompts for Accessibility after updates.
    func resetTCCIfSourceChanged() {
        let currentSource = installFingerprint()
        let previousSource = UserDefaults.standard.string(forKey: "installSource")

        if let previous = previousSource, previous != currentSource {
            Logging.log("install source changed (\(previous) → \(currentSource)), resetting TCC")
            resetAccessibilityGrant()
        }

        UserDefaults.standard.set(currentSource, forKey: "installSource")
    }

    /// Delete kanata-bar's Accessibility grant so the next `request` writes a fresh one.
    ///
    /// The grant's csreq is pinned to the cdhash that was current when it was granted,
    /// so after a rebuild/move the row can linger with the *old* cdhash: the toggle
    /// still shows ON but the HID layer rejects it, and on macOS 27 kanata then fails
    /// at its first gate and misreports "Input Monitoring denied". Toggling off/on
    /// won't fix it — only a remove+re-add rewrites the csreq, which is what deleting
    /// the row and re-requesting achieves. See the wiki gotchas
    /// "tcc-regrant-after-cdhash-change" and "stale-accessibility-csreq-looks-like-im-denied".
    /// (Input Monitoring is never requested — Accessibility covers input capture on
    /// modern macOS.)
    func resetAccessibilityGrant() {
        let bundleID = Bundle.main.bundleIdentifier ?? Constants.bundleID
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleID]
        try? tccutil.run()
        tccutil.waitUntilExit()
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
