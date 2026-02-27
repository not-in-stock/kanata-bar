import XCTest
@testable import KanataBarLib

final class TOMLParserTests: XCTestCase {

    // MARK: - Strings

    func testDoubleQuotedString() {
        let result = TOMLParser.parse(#"name = "hello""#)
        XCTAssertEqual(result["name"] as? String, "hello")
    }

    func testSingleQuotedString() {
        let result = TOMLParser.parse("name = 'hello'")
        XCTAssertEqual(result["name"] as? String, "hello")
    }

    func testStringWithSpaces() {
        let result = TOMLParser.parse(#"path = "/usr/local/bin/kanata""#)
        XCTAssertEqual(result["path"] as? String, "/usr/local/bin/kanata")
    }

    func testTildeExpansion() {
        let result = TOMLParser.parse(#"path = "~/configs/kanata.kbd""#)
        let expected = NSHomeDirectory() + "/configs/kanata.kbd"
        XCTAssertEqual(result["path"] as? String, expected)
    }

    // MARK: - Integers

    func testInteger() {
        let result = TOMLParser.parse("port = 5829")
        XCTAssertEqual(result["port"] as? Int, 5829)
    }

    func testZero() {
        let result = TOMLParser.parse("count = 0")
        XCTAssertEqual(result["count"] as? Int, 0)
    }

    // MARK: - Booleans

    func testTrue() {
        let result = TOMLParser.parse("autostart = true")
        XCTAssertEqual(result["autostart"] as? Bool, true)
    }

    func testFalse() {
        let result = TOMLParser.parse("autostart = false")
        XCTAssertEqual(result["autostart"] as? Bool, false)
    }

    // MARK: - Arrays

    func testStringArray() {
        let result = TOMLParser.parse(#"extra_args = ["--debug", "--verbose"]"#)
        XCTAssertEqual(result["extra_args"] as? [String], ["--debug", "--verbose"])
    }

    func testEmptyArray() {
        let result = TOMLParser.parse("extra_args = []")
        XCTAssertEqual(result["extra_args"] as? [String], [])
    }

    func testSingleQuotedArray() {
        let result = TOMLParser.parse("args = ['--flag']")
        XCTAssertEqual(result["args"] as? [String], ["--flag"])
    }

    // MARK: - Comments and whitespace

    func testCommentsIgnored() {
        let input = """
        # This is a comment
        port = 1234
        # Another comment
        """
        let result = TOMLParser.parse(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["port"] as? Int, 1234)
    }

    func testEmptyLinesIgnored() {
        let input = """

        port = 1234

        autostart = true

        """
        let result = TOMLParser.parse(input)
        XCTAssertEqual(result.count, 2)
    }

    func testWhitespaceAroundEquals() {
        let result = TOMLParser.parse("  port  =  5829  ")
        XCTAssertEqual(result["port"] as? Int, 5829)
    }

    // MARK: - Multiple keys

    func testMultipleKeys() {
        let input = """
        kanata = "/usr/bin/kanata"
        port = 5829
        autostart = true
        extra_args = ["--debug"]
        """
        let result = TOMLParser.parse(input)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result["kanata"] as? String, "/usr/bin/kanata")
        XCTAssertEqual(result["port"] as? Int, 5829)
        XCTAssertEqual(result["autostart"] as? Bool, true)
        XCTAssertEqual(result["extra_args"] as? [String], ["--debug"])
    }

    // MARK: - Edge cases

    func testEmptyInput() {
        let result = TOMLParser.parse("")
        XCTAssertTrue(result.isEmpty)
    }

    func testUnrecognizedLineSkipped() {
        let result = TOMLParser.parse("not a valid line")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyKeySkipped() {
        let result = TOMLParser.parse("= value")
        XCTAssertTrue(result.isEmpty)
    }

    func testUnquotedStringNotParsed() {
        let result = TOMLParser.parse("key = unquoted")
        XCTAssertNil(result["key"])
    }
}
