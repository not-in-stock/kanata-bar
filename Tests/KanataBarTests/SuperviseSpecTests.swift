import XCTest
import Shared

final class SuperviseSpecTests: XCTestCase {

    func testParsesFullSpec() throws {
        let spec = try SuperviseSpec.parse("""
        # kanata-bar supervise spec
        KANATA_BIN=/nix/store/abc/bin/kanata
        KANATA_CONFIG=/Users/me/.config/kanata/kanata.kbd
        KANATA_PORT=5829
        KANATA_EXTRA_ARGS=--debug --quiet
        KANATA_LOG=/Users/me/Library/Logs/kanata.log
        """)
        XCTAssertEqual(spec.kanataBin, "/nix/store/abc/bin/kanata")
        XCTAssertEqual(spec.configPath, "/Users/me/.config/kanata/kanata.kbd")
        XCTAssertEqual(spec.port, 5829)
        XCTAssertEqual(spec.extraArgs, ["--debug", "--quiet"])
        XCTAssertEqual(spec.logPath, "/Users/me/Library/Logs/kanata.log")
    }

    func testMinimalSpecHasNoExtrasOrLog() throws {
        let spec = try SuperviseSpec.parse("""
        KANATA_BIN=/usr/local/bin/kanata
        KANATA_CONFIG=/tmp/k.kbd
        KANATA_PORT=1234
        """)
        XCTAssertEqual(spec.extraArgs, [])
        XCTAssertNil(spec.logPath)
        XCTAssertEqual(spec.kanataArguments(), ["-c", "/tmp/k.kbd", "--port", "1234"])
    }

    func testKanataArgumentsAppendsExtras() throws {
        let spec = try SuperviseSpec.parse("""
        KANATA_BIN=/b/kanata
        KANATA_CONFIG=/c.kbd
        KANATA_PORT=9
        KANATA_EXTRA_ARGS=--nodelay
        """)
        XCTAssertEqual(spec.kanataArguments(), ["-c", "/c.kbd", "--port", "9", "--nodelay"])
    }

    func testStripsSurroundingQuotes() throws {
        let spec = try SuperviseSpec.parse("""
        KANATA_BIN="/path with space/kanata"
        KANATA_CONFIG='/cfg/k.kbd'
        KANATA_PORT=5829
        """)
        XCTAssertEqual(spec.kanataBin, "/path with space/kanata")
        XCTAssertEqual(spec.configPath, "/cfg/k.kbd")
    }

    func testIgnoresBlankLinesAndComments() throws {
        let spec = try SuperviseSpec.parse("""

        # comment
        KANATA_BIN=/b/kanata

        KANATA_CONFIG=/c.kbd
        KANATA_PORT=5829
        # trailing comment
        """)
        XCTAssertEqual(spec.kanataBin, "/b/kanata")
        XCTAssertEqual(spec.port, 5829)
    }

    func testMissingBinThrows() {
        XCTAssertThrowsError(try SuperviseSpec.parse("KANATA_CONFIG=/c.kbd\nKANATA_PORT=5829")) { error in
            XCTAssertEqual(error as? SuperviseSpec.ParseError, .missing("KANATA_BIN"))
        }
    }

    func testMissingConfigThrows() {
        XCTAssertThrowsError(try SuperviseSpec.parse("KANATA_BIN=/b/kanata\nKANATA_PORT=5829")) { error in
            XCTAssertEqual(error as? SuperviseSpec.ParseError, .missing("KANATA_CONFIG"))
        }
    }

    func testMissingPortThrows() {
        XCTAssertThrowsError(try SuperviseSpec.parse("KANATA_BIN=/b/kanata\nKANATA_CONFIG=/c.kbd")) { error in
            XCTAssertEqual(error as? SuperviseSpec.ParseError, .missing("KANATA_PORT"))
        }
    }

    func testInvalidPortThrows() {
        XCTAssertThrowsError(
            try SuperviseSpec.parse("KANATA_BIN=/b/kanata\nKANATA_CONFIG=/c.kbd\nKANATA_PORT=notaport")
        ) { error in
            XCTAssertEqual(error as? SuperviseSpec.ParseError, .invalidPort("notaport"))
        }
    }

    func testEmptyValueTreatedAsMissing() {
        XCTAssertThrowsError(
            try SuperviseSpec.parse("KANATA_BIN=\nKANATA_CONFIG=/c.kbd\nKANATA_PORT=5829")
        ) { error in
            XCTAssertEqual(error as? SuperviseSpec.ParseError, .missing("KANATA_BIN"))
        }
    }

    // Locks the stop-sentinel path formula: the app (StopSentinel, user side) and
    // the root supervisor (deriving it from $SUDO_UID's home) must agree byte for
    // byte, or Stop/reap silently breaks. This value must not change without a
    // migration — existing running wrappers poll the old path.
    func testStopSentinelPathFormula() {
        XCTAssertEqual(
            Constants.stopSentinelPath(home: "/Users/x"),
            "/Users/x/Library/Caches/com.kanata-bar/kanata-stop.sentinel")
    }
}
