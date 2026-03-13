import XCTest
@testable import KanataBarLib

final class CrashRateLimiterTests: XCTestCase {

    // MARK: - Basic behavior

    func testFirstCrashAllowed() {
        var limiter = CrashRateLimiter()
        XCTAssertTrue(limiter.recordCrash())
    }

    func testTwoCrashesAllowed() {
        var limiter = CrashRateLimiter()
        XCTAssertTrue(limiter.recordCrash())
        XCTAssertTrue(limiter.recordCrash())
    }

    func testThirdCrashDisables() {
        var limiter = CrashRateLimiter()
        XCTAssertTrue(limiter.recordCrash())
        XCTAssertTrue(limiter.recordCrash())
        XCTAssertFalse(limiter.recordCrash())
    }

    // MARK: - Window expiry

    func testOldCrashesExpire() {
        var limiter = CrashRateLimiter(maxCrashes: 3, window: 60)
        let old = Date(timeIntervalSinceNow: -61)
        XCTAssertTrue(limiter.recordCrash(at: old))
        XCTAssertTrue(limiter.recordCrash(at: old))

        // Two old crashes expired, so this is effectively the first
        let now = Date()
        XCTAssertTrue(limiter.recordCrash(at: now))
        XCTAssertTrue(limiter.recordCrash(at: now))
        // Third within window
        XCTAssertFalse(limiter.recordCrash(at: now))
    }

    func testCrashesJustInsideWindow() {
        var limiter = CrashRateLimiter(maxCrashes: 3, window: 60)
        let base = Date()
        XCTAssertTrue(limiter.recordCrash(at: base))
        XCTAssertTrue(limiter.recordCrash(at: base.addingTimeInterval(30)))
        XCTAssertFalse(limiter.recordCrash(at: base.addingTimeInterval(59)))
    }

    func testCrashesJustOutsideWindow() {
        var limiter = CrashRateLimiter(maxCrashes: 3, window: 60)
        let base = Date()
        XCTAssertTrue(limiter.recordCrash(at: base))
        XCTAssertTrue(limiter.recordCrash(at: base.addingTimeInterval(30)))
        // First crash expired (61s ago from perspective of third)
        XCTAssertTrue(limiter.recordCrash(at: base.addingTimeInterval(61)))
    }

    // MARK: - Custom limits

    func testCustomMaxCrashes() {
        var limiter = CrashRateLimiter(maxCrashes: 1, window: 60)
        XCTAssertFalse(limiter.recordCrash())
    }

    func testCustomWindow() {
        var limiter = CrashRateLimiter(maxCrashes: 3, window: 5)
        let base = Date()
        XCTAssertTrue(limiter.recordCrash(at: base))
        XCTAssertTrue(limiter.recordCrash(at: base.addingTimeInterval(1)))
        // First two expired (6s ago)
        XCTAssertTrue(limiter.recordCrash(at: base.addingTimeInterval(6)))
    }

    // MARK: - Reset

    func testReset() {
        var limiter = CrashRateLimiter()
        _ = limiter.recordCrash()
        _ = limiter.recordCrash()
        limiter.reset()
        XCTAssertTrue(limiter.timestamps.isEmpty)
        XCTAssertTrue(limiter.recordCrash())
    }
}
