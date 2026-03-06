import XCTest
@testable import KanataBarLib

final class TOMLDecoderTests: XCTestCase {

    // MARK: - Strings

    func testDoubleQuotedString() {
        let config = Config.decode("[kanata]\npath = \"hello\"")
        XCTAssertEqual(config.kanata.path, "hello")
    }

    func testSingleQuotedString() {
        let config = Config.decode("[kanata]\npath = 'hello'")
        XCTAssertEqual(config.kanata.path, "hello")
    }

    func testStringWithSpaces() {
        let config = Config.decode("[kanata]\npath = \"/usr/local/bin/kanata\"")
        XCTAssertEqual(config.kanata.path, "/usr/local/bin/kanata")
    }

    func testTildeExpansion() {
        let config = Config.decode("[kanata]\nconfig = \"~/configs/kanata.kbd\"")
        let expected = NSHomeDirectory() + "/configs/kanata.kbd"
        XCTAssertEqual(config.kanata.config, expected)
    }

    // MARK: - Integers

    func testInteger() {
        let config = Config.decode("[kanata]\nport = 5829")
        XCTAssertEqual(config.kanata.port, 5829)
    }

    func testZero() {
        let config = Config.decode("[kanata]\nport = 0")
        XCTAssertEqual(config.kanata.port, 0)
    }

    // MARK: - Booleans

    func testTrue() {
        let config = Config.decode("[kanata_bar]\nautostart_kanata = true")
        XCTAssertEqual(config.kanataBar.autostartKanata, true)
    }

    func testFalse() {
        let config = Config.decode("[kanata_bar]\nautostart_kanata = false")
        XCTAssertEqual(config.kanataBar.autostartKanata, false)
    }

    // MARK: - Arrays

    func testStringArray() {
        let config = Config.decode("[kanata]\nextra_args = [\"--debug\", \"--verbose\"]")
        XCTAssertEqual(config.kanata.extraArgs, ["--debug", "--verbose"])
    }

    func testEmptyArray() {
        let config = Config.decode("[kanata]\nextra_args = []")
        XCTAssertEqual(config.kanata.extraArgs, [])
    }

    func testSingleQuotedArray() {
        let config = Config.decode("[kanata]\nextra_args = ['--flag']")
        XCTAssertEqual(config.kanata.extraArgs, ["--flag"])
    }

    // MARK: - Comments and whitespace

    func testCommentsIgnored() {
        let input = """
        # This is a comment
        [kanata]
        port = 1234
        # Another comment
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.kanata.port, 1234)
    }

    func testWhitespaceAroundEquals() {
        let input = """
        [kanata]
          port  =  5829
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.kanata.port, 5829)
    }

    // MARK: - Multiple keys

    func testMultipleKeys() {
        let input = """
        [kanata]
        path = "/usr/bin/kanata"
        port = 5829
        extra_args = ["--debug"]

        [kanata_bar]
        autostart_kanata = true
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.kanata.path, "/usr/bin/kanata")
        XCTAssertEqual(config.kanata.port, 5829)
        XCTAssertEqual(config.kanataBar.autostartKanata, true)
        XCTAssertEqual(config.kanata.extraArgs, ["--debug"])
    }

    // MARK: - Partial config (missing keys use defaults)

    func testPartialConfigUsesDefaults() {
        let config = Config.decode("[kanata]\nport = 9999")
        XCTAssertEqual(config.kanata.port, 9999)
        XCTAssertEqual(config.kanata.path, Config.default.kanata.path)
        XCTAssertEqual(config.kanataBar.autostartKanata, Config.default.kanataBar.autostartKanata)
        XCTAssertEqual(config.kanata.extraArgs, Config.default.kanata.extraArgs)
    }

    func testEmptyInput() {
        let config = Config.decode("")
        XCTAssertEqual(config.kanata.port, Config.default.kanata.port)
        XCTAssertEqual(config.kanataBar.autostartKanata, Config.default.kanataBar.autostartKanata)
    }

    func testMissingSectionUsesDefaults() {
        let config = Config.decode("[kanata]\nport = 1234")
        XCTAssertEqual(config.kanata.port, 1234)
        XCTAssertEqual(config.kanataBar.autostartKanata, Config.default.kanataBar.autostartKanata)
        XCTAssertNil(config.kanataBar.iconsDir)
    }

    // MARK: - CodingKeys mapping

    func testSnakeCaseKeys() {
        let input = """
        [kanata]
        extra_args = ["--log"]
        pam_tid = "auto"

        [kanata_bar]
        icons_dir = "/path/to/icons"
        """
        let config = Config.decode(input)
        XCTAssertEqual(config.kanataBar.iconsDir, "/path/to/icons")
        XCTAssertEqual(config.kanata.extraArgs, ["--log"])
        XCTAssertEqual(config.kanata.pamTid, "auto")
    }

    // MARK: - IconTransition

    func testIconTransitionFlow() {
        let config = Config.decode("[kanata_bar]\nicon_transition = \"flow\"")
        XCTAssertEqual(config.kanataBar.iconTransition, .flow)
    }

    func testIconTransitionPages() {
        let config = Config.decode("[kanata_bar]\nicon_transition = \"pages\"")
        XCTAssertEqual(config.kanataBar.iconTransition, .pages)
    }

    func testIconTransitionCards() {
        let config = Config.decode("[kanata_bar]\nicon_transition = \"cards\"")
        XCTAssertEqual(config.kanataBar.iconTransition, .cards)
    }

    func testIconTransitionOff() {
        let config = Config.decode("[kanata_bar]\nicon_transition = \"off\"")
        XCTAssertEqual(config.kanataBar.iconTransition, .off)
    }

    func testIconTransitionDefault() {
        let config = Config.decode("[kanata]\nport = 5829")
        XCTAssertNil(config.kanataBar.iconTransition)
    }

    func testIconTransitionInvalidValue() {
        let config = Config.decode("[kanata_bar]\nicon_transition = \"invalid\"")
        XCTAssertNil(config.kanataBar.iconTransition)
    }
}
