import AppKit
import ApplicationServices
import CoreGraphics
import Shared

/// Drives the two TCC grants kanata needs — Input Monitoring and Accessibility —
/// from the app's user-session context.
///
/// kanata always runs as root (helper or sudo), so it can never trigger the
/// consent dialogs itself: a root process has no user session to prompt in. But
/// both grants attach to the *responsible process* — this app, `com.kanata-bar` —
/// and root-launched kanata inherits them (proven on the stand: a pre-granted
/// `com.kanata-bar` row is honoured on both the helper and the sudo path). So the
/// app requests them on kanata's behalf, exactly the way Karabiner-Elements' UI
/// app holds Input Monitoring for its root daemon.
@MainActor
enum TCCPermissions {
    enum Kind: CaseIterable {
        case inputMonitoring
        case accessibility
    }

    /// Whether a grant is currently held. Cheap, side-effect-free — safe to poll
    /// (e.g. every time the menu opens).
    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .inputMonitoring:
            // kTCCServiceListenEvent via CoreGraphics. Same TCC service kanata's
            // IOKit-HID check reads, but the CG request API (below) reliably shows
            // the dialog where IOHIDRequestAccess did not.
            return CGPreflightListenEventAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    static var allGranted: Bool { Kind.allCases.allSatisfy(isGranted) }

    static var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }

    /// Ask macOS to surface a grant. No dialog if it's already decided.
    ///
    /// - Input Monitoring: `CGRequestListenEventAccess` shows the dialog and adds
    ///   the app to the list. (We used `IOHIDRequestAccess` before, but on current
    ///   macOS it neither prompted nor registered the app — the CoreGraphics API
    ///   for the same `kTCCServiceListenEvent` service does both.)
    /// - Accessibility: `AXIsProcessTrustedWithOptions(prompt)` adds the app to the
    ///   list and shows the "grant in System Settings" prompt. The user still flips
    ///   the toggle — macOS forbids enabling Accessibility programmatically.
    @discardableResult
    static func request(_ kind: Kind) -> Bool {
        switch kind {
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .accessibility:
            // `kAXTrustedCheckOptionPrompt` is a global `var` (CFStringRef) that
            // trips strict concurrency, so reference its stable literal value
            // instead. `kCFBooleanTrue` (an immutable global) is the value the
            // API expects.
            let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Open the exact System Settings pane for a grant, so the user isn't left
    /// hunting through Privacy & Security for the right toggle.
    static func openSettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Human-readable name for menus and alerts.
    static func label(_ kind: Kind) -> String {
        switch kind {
        case .inputMonitoring: return NSLocalizedString("permissions.inputMonitoring", comment: "")
        case .accessibility: return NSLocalizedString("permissions.accessibility", comment: "")
        }
    }
}
