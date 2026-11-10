import XCTest
@testable import KanataBarLib

final class KanataFailureTests: XCTestCase {

    // Real kanata log lines (verbatim shapes) for each failure mode.

    func testInputMonitoringDeniedIsPermission() {
        let log = """
        10:07:50.091 [INFO] entering the event loop
        10:07:50.093 [ERROR] failed to open keyboard device(s): macOS Input Monitoring permission is denied for kanata. Enable kanata in System Settings -> Privacy & Security -> Input Monitoring, then re-run kanata.
        """
        XCTAssertEqual(KanataFailure.classify(logTail: log), .permissionDenied)
    }

    func testAccessibilityDeniedIsPermission() {
        // kanata's own wording once the IM gate passes — still one permission problem.
        let log = "failed to open keyboard device(s): kanata needs macOS Accessibility permission. Enable kanata in System Settings."
        XCTAssertEqual(KanataFailure.classify(logTail: log), .permissionDenied)
    }

    func testIOHIDDeviceOpenErrorIsPermission() {
        let log = "IOHIDDeviceOpen error: (iokit/common) not permitted"
        XCTAssertEqual(KanataFailure.classify(logTail: log), .permissionDenied)
    }

    func testPortInUseIsPortConflict() {
        let log = "[ERROR] TCP server could not bind: Address already in use (os error 48)"
        XCTAssertEqual(KanataFailure.classify(logTail: log), .portInUse)
    }

    func testPortMatchIsCaseInsensitive() {
        XCTAssertEqual(KanataFailure.classify(logTail: "error: address in use"), .portInUse)
    }

    func testCleanRunIsUnknown() {
        let log = """
        10:07:50.091 [INFO] entering the processing loop
        10:07:50.092 [INFO] virtual_hid_keyboard_ready true
        """
        XCTAssertEqual(KanataFailure.classify(logTail: log), .unknown)
    }

    func testPermissionWinsOverPortWhenBothPresent() {
        // A permission denial is the actionable cause; prefer it.
        let log = """
        Address already in use
        macOS Input Monitoring permission is denied for kanata
        """
        XCTAssertEqual(KanataFailure.classify(logTail: log), .permissionDenied)
    }

    // MARK: - tail(ofFileAt:)

    func testTailReadsOnlyTheLastBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanata-failure-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = String(repeating: "x\n", count: 10_000) + "macOS Input Monitoring permission is denied for kanata\n"
        try body.write(to: url, atomically: true, encoding: .utf8)

        let tail = try XCTUnwrap(KanataFailure.tail(ofFileAt: url.path, maxBytes: 256))
        XCTAssertLessThanOrEqual(tail.utf8.count, 256)
        XCTAssertTrue(tail.contains("Input Monitoring permission is denied"))
        XCTAssertEqual(KanataFailure.classify(logPath: url.path, maxBytes: 256), .permissionDenied)
    }

    func testMissingFileIsUnknown() {
        XCTAssertNil(KanataFailure.tail(ofFileAt: "/nonexistent/kanata.log", maxBytes: 256))
        XCTAssertEqual(KanataFailure.classify(logPath: "/nonexistent/kanata.log"), .unknown)
    }
}
