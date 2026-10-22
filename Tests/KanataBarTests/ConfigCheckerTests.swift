import XCTest
@testable import KanataBarLib

final class ConfigCheckerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("config-checker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Captured from kanata 1.12.0 `--check` on a layer with too few items.
    private let kanataError = """
    20:53:21.8637 \u{1B}[0m\u{1B}[31m[ERROR] \u{1B}[0m  × Error in configuration
       ╭─[bad.kbd:1:1]
     1 │ (defsrc a b)
     2 │ (deflayer base a)
       · ────────┬────────
       ·         ╰── Error here
       ╰────
      help: Layer base has 1 item(s), but requires 2 to match defsrc
            \n\
            For more info, see the configuration guide:
            https://github.com/jtroo/kanata/blob/main/docs/config.adoc
    """

    /// Writes an executable that mimics `kanata --check`: exits `status`, prints `stderr`.
    private func fakeKanata(status: Int32, stderr: String = "", stdout: String = "", sleep: Int = 0) throws -> String {
        let path = dir.appendingPathComponent("kanata").path
        let script = """
        #!/bin/sh
        [ "$1" = "--check" ] && [ "$2" = "-c" ] || { echo "bad args: $*" >&2; exit 64; }
        [ \(sleep) -gt 0 ] && sleep \(sleep)
        printf '%s' '\(stdout.replacingOccurrences(of: "'", with: "'\\''"))'
        printf '%s' '\(stderr.replacingOccurrences(of: "'", with: "'\\''"))' >&2
        exit \(status)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    // MARK: - Summary parsing

    func testSummaryUsesLocationAndHelpLine() {
        let s = ConfigChecker.summarize(ConfigChecker.stripANSI(kanataError))
        XCTAssertEqual(s, "bad.kbd:1:1: Layer base has 1 item(s), but requires 2 to match defsrc")
    }

    func testSummaryFallsBackToErrorLine() {
        let text = "12:00:00.0000 [ERROR] Could not find the config file (nope.kbd)\nFor more info, pass -h"
        XCTAssertEqual(ConfigChecker.summarize(text), "Could not find the config file (nope.kbd)")
    }

    func testSummaryWithNothingRecognisable() {
        XCTAssertEqual(ConfigChecker.summarize("garbage"), "invalid config")
    }

    func testStripANSI() {
        XCTAssertEqual(ConfigChecker.stripANSI("\u{1B}[0m\u{1B}[31m[ERROR] \u{1B}[0mx"), "[ERROR] x")
    }

    // MARK: - Running the binary

    func testValidConfig() async throws {
        let bin = try fakeKanata(status: 0, stdout: "[INFO] config file is valid\n")
        let outcome = await ConfigChecker(binaryPath: bin).check(configPath: "/x/kanata.kbd")
        XCTAssertEqual(outcome, .valid)
    }

    func testInvalidConfigIsSummarised() async throws {
        let bin = try fakeKanata(status: 1, stderr: kanataError)
        let outcome = await ConfigChecker(binaryPath: bin).check(configPath: "/x/kanata.kbd")
        guard case .invalid(let summary, let details) = outcome else {
            return XCTFail("expected invalid, got \(outcome)")
        }
        XCTAssertEqual(summary, "bad.kbd:1:1: Layer base has 1 item(s), but requires 2 to match defsrc")
        XCTAssertTrue(details.contains("Error in configuration"))
        XCTAssertFalse(details.contains("\u{1B}["), "ANSI codes must be stripped from details")
    }

    func testMissingBinaryFails() async {
        let outcome = await ConfigChecker(binaryPath: dir.appendingPathComponent("nope").path).check(configPath: "/x")
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }

    func testRealKanataIfPresent() async throws {
        // Optional end-to-end check against the user's actual binary.
        let candidates = ["/opt/homebrew/bin/kanata", "/run/current-system/sw/bin/kanata"]
            + (ProcessInfo.processInfo.environment["KANATA_BIN"].map { [$0] } ?? [])
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no kanata binary on this machine")
        }
        let good = dir.appendingPathComponent("good.kbd").path
        let bad = dir.appendingPathComponent("bad.kbd").path
        try "(defsrc a b)\n(deflayer base a b)\n".write(toFile: good, atomically: true, encoding: .utf8)
        try "(defsrc a b)\n(deflayer base a)\n".write(toFile: bad, atomically: true, encoding: .utf8)
        let checker = ConfigChecker(binaryPath: bin)
        let goodOutcome = await checker.check(configPath: good)
        XCTAssertEqual(goodOutcome, .valid)
        let badOutcome = await checker.check(configPath: bad)
        guard case .invalid(let summary, _) = badOutcome else { return XCTFail("expected invalid, got \(badOutcome)") }
        XCTAssertTrue(summary.hasPrefix("bad.kbd:"), summary)
        XCTAssertTrue(summary.contains("requires 2"), summary)
    }
}
