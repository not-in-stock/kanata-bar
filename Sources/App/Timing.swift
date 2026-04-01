import Foundation

/// Named timing constants used across the app.
enum Timing {
    /// Wait for kanata to start before discovering its PID via pgrep.
    static let pidDiscoveryDelay: UInt64 = 1_500_000_000 // nanoseconds

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
}
