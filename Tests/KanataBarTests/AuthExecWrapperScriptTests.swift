import XCTest
@testable import KanataBarLib

final class AuthExecWrapperScriptTests: XCTestCase {

    private let script = AuthExecLauncher.makeWrapperScript(
        kanataCommand: "'/opt/kanata' -c '/tmp/k.kbd'", appPID: 123, sentinelPath: "/tmp/stop.sentinel")

    func testReportsKanataPIDOnFirstLine() {
        XCTAssertTrue(script.contains("KPID=$!; echo $KPID"))
    }

    func testTrapKillsKanataOnExit() {
        XCTAssertTrue(script.contains("trap 'kill -KILL $KPID 2>/dev/null' EXIT"))
    }

    /// Regression: the watchdog loop must end when kanata dies, the app dies, OR
    /// the stop sentinel is deleted. Watching only the app left a root shell running
    /// after every Stop, whose EXIT trap later SIGKILLed a recycled pid; watching
    /// the sentinel is what makes Stop privilege-free (no AuthExec/sudo re-prompt).
    func testWatchdogWatchesKanataAppAndSentinel() {
        XCTAssertTrue(script.contains(
            "while kill -0 $KPID 2>/dev/null && kill -0 123 2>/dev/null && [ -e '/tmp/stop.sentinel' ]; do"))
    }

    func testWatchdogWatchesStopSentinel() {
        XCTAssertTrue(script.contains("[ -e '/tmp/stop.sentinel' ]"))
    }

    func testEmbedsKanataCommandInBackground() {
        XCTAssertTrue(script.hasPrefix("'/opt/kanata' -c '/tmp/k.kbd' & "))
    }
}
