import XCTest
@testable import KanataBarLib

final class TOMLDecoderTests: XCTestCase {

    // MARK: - Strings

    func testDoubleQuotedString() {
        let config = Config.decode(#"kanata = "hello""#)
        XCTAssertEqual(config.kanata, "hello")
    }

    func testSingleQuotedString() {
        let config = Config.decode("kanata = 'hello'")
        XCTAssertEqual(config.kanata, "hello")
    }

    func testStringWithSpaces() {
        let config = Config.decode(#"kanata = "/usr/local/bin/kanata""#)
        XCTAssertEqual(config.kanata, "/usr/local/bin/kanata")
    }

    func testTildeExpansion() {
        let config = Config.decode(#"config = "~/configs/kanata.kbd""#)
        let expected = NSHomeDirectory() + "/configs/kanata.kbd"
        XCTAssertEqual(config.config, expected)
    }

    // MARK: - Integers

    func testInteger() {
        let config = Config.decode("port = 5829")
        XCTAssertEqual(config.port, 5829)
    }

    func testZero() {
        let config = Config.decode("port = 0")
        XCTAssertEqual(config.port, 0)
    }

    // MARK: - Booleans

    func testTrue() {
        let config = Config.decode("autostart = true")
        XCTAssertEqual(config.autostart, true)
    }

    func testFalse() {
        let config = Config.decode("autostart = false")
        XCTAssertEqual(config.autostart, false)
    }

    // MARK: - Arrays

    func testStringArray() {
        let config = Config.decode(#"extra_args = ["--debug", "--verbose"]"#)
        XCTAssertEqual(config.extraArgs, ["--debug", "--verbose"])
    }

    func testEmptyArray() {
        let config = Config.decode("extra_args = []")
        XCTAssertEqual(config.extraArgs, [])
    }

    func testSingleQuotedArray() {
        let config = Config.decode("extra_args = ['--flag']")
        XCTAssertEqual(config.extraArgs, ["--flag"])
    }

    // MARK: - Comments and whitespace

    func testCommentsIgnored() {
        let input = """
        # This is a comment
        port = 1234
        # Another comment
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.port, 1234)
    }

    func testWhitespaceAroundEquals() {
        let config = Config.decode("  port  =  5829  ")
        XCTAssertEqual(config.port, 5829)
    }

    // MARK: - Multiple keys

    func testMultipleKeys() {
        let input = """
        kanata = "/usr/bin/kanata"
        port = 5829
        autostart = true
        extra_args = ["--debug"]
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.kanata, "/usr/bin/kanata")
        XCTAssertEqual(config.port, 5829)
        XCTAssertEqual(config.autostart, true)
        XCTAssertEqual(config.extraArgs, ["--debug"])
    }

    // MARK: - Partial config (missing keys use defaults)

    func testPartialConfigUsesDefaults() {
        let config = Config.decode("port = 9999")
        XCTAssertEqual(config.port, 9999)
        XCTAssertEqual(config.kanata, Config.default.kanata)
        XCTAssertEqual(config.autostart, Config.default.autostart)
        XCTAssertEqual(config.extraArgs, Config.default.extraArgs)
    }

    func testEmptyInput() {
        let config = Config.decode("")
        XCTAssertEqual(config.port, Config.default.port)
        XCTAssertEqual(config.autostart, Config.default.autostart)
    }

    // MARK: - CodingKeys mapping

    func testSnakeCaseKeys() {
        let input = """
        icons_dir = "/path/to/icons"
        extra_args = ["--log"]
        pam_tid = "auto"
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.iconsDir, "/path/to/icons")
        XCTAssertEqual(config.extraArgs, ["--log"])
        XCTAssertEqual(config.pamTid, "auto")
    }
}
