import XCTest
@testable import KanataBarLib

final class ConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultValues() {
        let config = Config.default
        XCTAssertEqual(config.kanata, "")
        XCTAssertEqual(config.config, "~/.config/kanata/kanata.kbd")
        XCTAssertEqual(config.port, 5829)
        XCTAssertNil(config.iconsDir)
        XCTAssertTrue(config.autostart)
        XCTAssertFalse(config.autorestart)
        XCTAssertEqual(config.extraArgs, [])
    }

    func testLoadNonexistentFileReturnsDefaults() {
        let config = Config.load(from: "/nonexistent/path/config.toml")
        XCTAssertEqual(config.port, Config.default.port)
        XCTAssertEqual(config.autostart, Config.default.autostart)
    }

    func testLoadNilPathNoDefaultFileReturnsDefaults() {
        // If no default config file exists, should return defaults
        let config = Config.load(from: nil)
        XCTAssertEqual(config.port, Config.default.port)
    }

    // MARK: - expandTilde

    func testExpandTildeWithTilde() {
        let result = Config.expandTilde("~/Documents")
        XCTAssertEqual(result, NSHomeDirectory() + "/Documents")
    }

    func testExpandTildeWithoutTilde() {
        let result = Config.expandTilde("/usr/bin/kanata")
        XCTAssertEqual(result, "/usr/bin/kanata")
    }

    func testExpandTildeEmptyString() {
        let result = Config.expandTilde("")
        XCTAssertEqual(result, "")
    }

    func testExpandTildeMidString() {
        // ~ in middle should not expand
        let result = Config.expandTilde("/home/~/test")
        XCTAssertEqual(result, "/home/~/test")
    }

    // MARK: - resolveKanataPath

    func testResolveExplicitPath() {
        let result = Config.resolveKanataPath("/usr/local/bin/kanata")
        XCTAssertEqual(result, "/usr/local/bin/kanata")
    }

    func testResolvePathWithTilde() {
        let result = Config.resolveKanataPath("~/bin/kanata")
        XCTAssertEqual(result, NSHomeDirectory() + "/bin/kanata")
    }
}
