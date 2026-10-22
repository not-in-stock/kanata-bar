import Foundation

/// Named timing constants used across the app.
enum Timing {
    /// Grace period after sending SIGKILL before freeing resources.
    static let cleanupGracePeriod: useconds_t = 500_000 // microseconds

    /// How long to wait for TCP connection before warning about port conflict.
    static let tcpConnectTimeout: Duration = .seconds(10)

    /// How long to wait for external kanata to respond before giving up.
    static let externalKanataTimeout: Duration = .seconds(5)

    /// Delay before autorestarting a crashed kanata process.
    static let restartDelay: Duration = .seconds(2)

    /// Initial TCP reconnect delay (doubles on each failure up to `maxReconnectDelay`).
    static let initialReconnectDelay: TimeInterval = 1.0

    /// Maximum TCP reconnect backoff.
    static let maxReconnectDelay: TimeInterval = 10.0

    /// TCP receive buffer size in bytes.
    static let tcpBufferSize = 4096

    /// Kill `kanata --check` if it has not exited by then.
    static let configCheckTimeout: TimeInterval = 10

    /// Debounce window for config-file saves before auto-reload.
    static let configWatchDebounce: TimeInterval = 0.3
}

// MARK: - HUD keyboard

extension Timing {
    /// How long a resolved tap stays highlighted on the HUD.
    static let hudTapFlash: TimeInterval = 0.15

    /// Ignore modifier-release evidence this soon after HoldActivated: kanata's
    /// modifier DOWN and the TCP message arrive in either order ~20 ms apart.
    static let hudHoldGrace: TimeInterval = 0.05

    /// Hold state for actions with no observable end (macro, cmd, …).
    static let hudHoldFallback: TimeInterval = 2.0

    /// Safety cap for any hold whose end signal was missed.
    static let hudHoldHardLimit: TimeInterval = 15.0

    /// Housekeeping tick while flashes or holds are live.
    static let hudTick: TimeInterval = 0.05

    /// Poll interval for the Accessibility grant before installing the HUD's event tap.
    static let hudTapRetry: TimeInterval = 2.0
}
