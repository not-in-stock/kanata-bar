import Foundation
import Shared

/// Why kanata exited, inferred from the tail of its log.
///
/// kanata's own error text can name the *wrong* permission: on macOS it checks
/// Input Monitoring before Accessibility, so a process whose grant isn't honored
/// fails at the first gate and prints "Input Monitoring permission is denied" even
/// when the real gap is **Accessibility** (the only permission kanata-bar requests —
/// Accessibility covers input capture on modern macOS). So we fold every permission
/// signature, either pane, into a single `.permissionDenied` and let the app steer to
/// Accessibility. See the wiki gotcha
/// "stale-accessibility-csreq-looks-like-im-denied".
enum KanataFailure: Equatable, Sendable {
    case permissionDenied
    case portInUse
    case unknown

    /// Substrings kanata prints on a permission failure — either pane, and the
    /// underlying IOKit error behind both (#1211).
    static let permissionSignatures = [
        "Input Monitoring permission is denied",
        "needs macOS Input Monitoring permission",
        "needs macOS Accessibility permission",
        "IOHIDDeviceOpen error",
    ]
    /// Substrings kanata prints when the TCP port is taken (matched case-insensitively).
    static let portSignatures = [
        "address already in use",
        "address in use",
    ]

    /// Classify an already-read log tail. Pure — the unit-test entry point.
    static func classify(logTail: String) -> KanataFailure {
        if permissionSignatures.contains(where: logTail.contains) { return .permissionDenied }
        let lower = logTail.lowercased()
        if portSignatures.contains(where: lower.contains) { return .portInUse }
        return .unknown
    }

    /// Read the last `maxBytes` of the log at `path` and classify it. Cheap — called
    /// only on an abnormal exit, and bounded so a huge log can't be slurped whole.
    static func classify(logPath: String, maxBytes: Int = 16_384) -> KanataFailure {
        guard let tail = tail(ofFileAt: logPath, maxBytes: maxBytes) else { return .unknown }
        return classify(logTail: tail)
    }

    /// Last `maxBytes` of a file as UTF-8 (lossy), or nil if it can't be opened.
    static func tail(ofFileAt path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(bytes: data, encoding: .utf8)
    }
}
