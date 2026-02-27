import XCTest
@testable import KanataBarLib

final class AppStateTests: XCTestCase {

    func testEquatable() {
        XCTAssertEqual(AppState.stopped, AppState.stopped)
        XCTAssertEqual(AppState.starting, AppState.starting)
        XCTAssertEqual(AppState.restarting, AppState.restarting)
        XCTAssertEqual(AppState.running("base"), AppState.running("base"))
    }

    func testNotEqual() {
        XCTAssertNotEqual(AppState.stopped, AppState.starting)
        XCTAssertNotEqual(AppState.running("base"), AppState.running("nav"))
        XCTAssertNotEqual(AppState.starting, AppState.restarting)
    }

    func testRunningDifferentLayers() {
        XCTAssertNotEqual(AppState.running("base"), AppState.running("nav"))
    }
}
