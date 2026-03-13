import XCTest
@testable import KanataBarLib

final class ConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultValues() {
        let config = Config.default
        XCTAssertEqual(config.kanata.path, "")
        XCTAssertEqual(config.kanata.config, "~/.config/kanata/kanata.kbd")
        XCTAssertEqual(config.kanata.port, 5829)
        XCTAssertEqual(config.kanata.extraArgs, [])
        XCTAssertNil(config.kanataBar.iconsDir)
        XCTAssertFalse(config.kanataBar.autostartKanata)
        XCTAssertFalse(config.kanataBar.autorestartKanata)
    }

    func testLoadNonexistentFileReturnsDefaults() {
        let config = Config.load(from: "/nonexistent/path/config.toml")
        XCTAssertEqual(config.kanata.port, Config.default.kanata.port)
        XCTAssertEqual(config.kanataBar.autostartKanata, Config.default.kanataBar.autostartKanata)
    }

    func testLoadNilPathNoDefaultFileReturnsDefaults() {
        let config = Config.load(from: nil)
        XCTAssertEqual(config.kanata.port, Config.default.kanata.port)
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

    // MARK: - isBinaryAccessible

    func testIsBinaryAccessibleWithRealExecutable() {
        XCTAssertTrue(Config.isBinaryAccessible("/bin/ls"))
    }

    func testIsBinaryAccessibleWithNonexistentPath() {
        XCTAssertFalse(Config.isBinaryAccessible("/nonexistent/path/kanata"))
    }

    func testIsBinaryAccessibleWithBareName() {
        XCTAssertFalse(Config.isBinaryAccessible("kanata"))
    }

    func testIsBinaryAccessibleWithNonExecutableFile() throws {
        let tmp = NSTemporaryDirectory() + "kanata-bar-test-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: tmp, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertFalse(Config.isBinaryAccessible(tmp))
    }

    func testIsBinaryAccessibleWithDirectory() {
        XCTAssertFalse(Config.isBinaryAccessible("/usr/bin"))
    }
}
