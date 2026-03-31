import XCTest
@testable import KanataBarLib

final class ShellEscapeTests: XCTestCase {

    func testSimpleString() {
        XCTAssertEqual(AuthExecLauncher.shellEscape("hello"), "'hello'")
    }

    func testStringWithSingleQuote() {
        XCTAssertEqual(AuthExecLauncher.shellEscape("it's"), "'it'\\''s'")
    }

    func testEmptyString() {
        XCTAssertEqual(AuthExecLauncher.shellEscape(""), "''")
    }
}
