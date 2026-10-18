import XCTest
@testable import KanataBarLib

final class AuthExecWrapperScriptTests: XCTestCase {

    private let script = AuthExecLauncher.makeWrapperScript(kanataCommand: "'/opt/kanata' -c '/tmp/k.kbd'", appPID: 123)

    func testReportsKanataPIDOnFirstLine() {
        XCTAssertTrue(script.contains("KPID=$!; echo $KPID"))
    }

    func testTrapKillsKanataOnExit() {
        XCTAssertTrue(script.contains("trap 'kill -KILL $KPID 2>/dev/null' EXIT"))
    }

    /// Regression: the watchdog loop must end when *either* kanata or the app dies.
    /// Watching only the app left a root shell running after every Stop, whose EXIT
    /// trap later SIGKILLed a long-dead (possibly recycled) pid.
    func testWatchdogWatchesBothKanataAndApp() {
        XCTAssertTrue(script.contains("while kill -0 $KPID 2>/dev/null && kill -0 123 2>/dev/null; do"))
    }

    func testEmbedsKanataCommandInBackground() {
        XCTAssertTrue(script.hasPrefix("'/opt/kanata' -c '/tmp/k.kbd' & "))
    }
}
