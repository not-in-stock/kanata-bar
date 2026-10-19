import AppKit
import ApplicationServices
import Shared

/// Drives the Accessibility TCC grant kanata needs, from the app's user-session
/// context.
///
/// kanata always runs as root (helper or sudo), so it can never trigger the
/// consent dialog itself: a root process has no user session to prompt in. The
/// grant attaches to the *responsible process* — this app, `com.kanata-bar` — and
/// root-launched kanata inherits it (proven on the stand on both the helper and the
/// sudo path), exactly the way Karabiner-Elements' UI app holds the grant for its
/// root daemon.
///
/// On modern macOS **Accessibility covers input capture**, so Input Monitoring is no
/// longer requested (Karabiner-Elements 16.0.0+ does the same; confirmed 2026-10-19
/// — see the wiki gotcha "kanata needs Accessibility"). `Kind` stays an enum so a
/// manual Input-Monitoring fallback can be reintroduced if an old macOS ever needs it.
@MainActor
enum TCCPermissions {
    enum Kind: CaseIterable {
        case accessibility
    }

    /// Whether a grant is currently held. Cheap, side-effect-free — safe to poll
    /// (e.g. every time the menu opens).
    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    static var allGranted: Bool { Kind.allCases.allSatisfy(isGranted) }

    static var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }

    /// Ask macOS to surface a grant. No dialog if it's already decided.
    ///
    /// `AXIsProcessTrustedWithOptions(prompt)` adds the app to the Accessibility list
    /// and shows the "grant in System Settings" prompt. The user still flips the
    /// toggle — macOS forbids enabling Accessibility programmatically — but, unlike
    /// Input Monitoring, it applies live with no "Quit & Reopen".
    @discardableResult
    static func request(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:
            // `kAXTrustedCheckOptionPrompt` is a global `var` (CFStringRef) that trips
            // strict concurrency, so reference its stable literal value instead.
            // `kCFBooleanTrue` (an immutable global) is the value the API expects.
            let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Open the exact System Settings pane for a grant, so the user isn't left
    /// hunting through Privacy & Security for the right toggle.
    static func openSettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Human-readable name for menus and alerts.
    static func label(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: return NSLocalizedString("permissions.accessibility", comment: "")
        }
    }
}
