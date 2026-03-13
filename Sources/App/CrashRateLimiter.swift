import Foundation

/// Tracks crash timestamps and determines if autorestart should be disabled.
struct CrashRateLimiter {
    private(set) var timestamps: [Date] = []
    let maxCrashes: Int
    let window: TimeInterval

    init(maxCrashes: Int = 3, window: TimeInterval = 60) {
        self.maxCrashes = maxCrashes
        self.window = window
    }

    /// Records a crash and returns whether autorestart should continue.
    mutating func recordCrash(at now: Date = Date()) -> Bool {
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        timestamps.append(now)
        return timestamps.count < maxCrashes
    }

    mutating func reset() {
        timestamps = []
    }
}
