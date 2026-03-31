import XCTest
@testable import KanataBarLib

/// A mock launcher that lets tests trigger callbacks directly.
@MainActor
private class MockLauncher: KanataLauncher {
    var startCount = 0
    var stopCount = 0
    var cleanupCount = 0

    var onStarted: ((Int32) -> Void)?
    var onExited: ((Int32) -> Void)?
    var onFailure: (() -> Void)?
    var onError: ((String) -> Void)?

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func cleanup() { cleanupCount += 1 }

    // Test helpers — simulate launcher callbacks
    func simulateStarted(pid: Int32) { onStarted?(pid) }
    func simulateExited(code: Int32) { onExited?(code) }
    func simulateFailure() { onFailure?() }
    func simulateError(_ msg: String) { onError?(msg) }
}

@MainActor
final class KanataProcessTests: XCTestCase {

    private func makeProcess() -> (KanataProcess, MockLauncher) {
        let launcher = MockLauncher()
        let process = KanataProcess(launcher: launcher, binaryPath: "/usr/bin/kanata", configPath: "/tmp/config.kbd", port: 5829)
        return (process, launcher)
    }

    // MARK: - Start

    func testStartDelegatesToLauncher() {
        let (process, launcher) = makeProcess()
        process.start()

        XCTAssertEqual(launcher.startCount, 1)
        XCTAssertTrue(process.isRunning)
    }

    func testStartIgnoredWhenAlreadyRunning() {
        let (process, launcher) = makeProcess()
        process.start()
        process.start()

        XCTAssertEqual(launcher.startCount, 1)
    }

    func testStartCallsStateChangeWithTrue() {
        let (process, _) = makeProcess()
        var states: [Bool] = []
        process.onStateChange = { states.append($0) }
        process.start()

        XCTAssertEqual(states, [true])
    }

    // MARK: - PID Discovery

    func testPIDFoundCallback() {
        let (process, launcher) = makeProcess()
        var foundPID: Int32?
        process.onPIDFound = { foundPID = $0 }
        process.start()
        launcher.simulateStarted(pid: 12345)

        XCTAssertEqual(process.kanataPID, 12345)
        XCTAssertEqual(foundPID, 12345)
    }

    // MARK: - Normal Exit

    func testNormalExitAfterStop() {
        let (process, launcher) = makeProcess()
        var crashed = false
        process.onCrash = { _ in crashed = true }
        process.start()
        launcher.simulateStarted(pid: 100)
        process.stop()
        launcher.simulateExited(code: 0)

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.kanataPID, -1)
        XCTAssertFalse(crashed)
    }

    func testStopDelegatesToLauncher() {
        let (process, launcher) = makeProcess()
        process.start()
        process.stop()

        XCTAssertEqual(launcher.stopCount, 1)
    }

    // MARK: - Crash Detection

    func testCrashAfterPIDDiscovery() {
        let (process, launcher) = makeProcess()
        var crashCode: Int32?
        process.onCrash = { crashCode = $0 }
        process.start()
        launcher.simulateStarted(pid: 100)
        launcher.simulateExited(code: 1)

        XCTAssertEqual(crashCode, 1)
        XCTAssertFalse(process.isRunning)
    }

    func testEarlyExitBeforePIDDiscovery() {
        let (process, launcher) = makeProcess()
        var earlyExitCode: Int32?
        var crashCode: Int32?
        process.onEarlyExit = { earlyExitCode = $0 }
        process.onCrash = { crashCode = $0 }
        process.start()
        // No simulateStarted — PID never discovered
        launcher.simulateExited(code: 1)

        XCTAssertEqual(earlyExitCode, 1)
        XCTAssertNil(crashCode)
    }

    func testExitWithZeroCodeNotReportedAsCrash() {
        let (process, launcher) = makeProcess()
        var crashed = false
        var earlyExit = false
        process.onCrash = { _ in crashed = true }
        process.onEarlyExit = { _ in earlyExit = true }
        process.start()
        launcher.simulateExited(code: 0)

        XCTAssertFalse(crashed)
        XCTAssertFalse(earlyExit)
    }

    // MARK: - Start Failure

    func testStartFailureCallback() {
        let (process, launcher) = makeProcess()
        var failed = false
        process.onStartFailure = { failed = true }
        process.start()
        launcher.simulateFailure()

        XCTAssertTrue(failed)
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - Error

    func testErrorCallback() {
        let (process, launcher) = makeProcess()
        var errorMsg: String?
        process.onError = { errorMsg = $0 }
        process.start()
        launcher.simulateError("binary not found")

        XCTAssertEqual(errorMsg, "binary not found")
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - State Change

    func testStateChangeOnExited() {
        let (process, launcher) = makeProcess()
        var states: [Bool] = []
        process.onStateChange = { states.append($0) }
        process.start()
        launcher.simulateExited(code: 0)

        XCTAssertEqual(states, [true, false])
    }

    // MARK: - ForceKillAll

    func testForceKillAllDelegatesToCleanup() {
        let (process, launcher) = makeProcess()
        process.forceKillAll()

        XCTAssertEqual(launcher.cleanupCount, 1)
    }
}
