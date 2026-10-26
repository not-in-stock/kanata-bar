import XCTest
@testable import KanataBarLib

@MainActor
final class AutoReloaderTests: XCTestCase {

    /// Scripted dependencies: the check outcome queue, reload counter and a
    /// watcher factory that records what was watched. The watcher itself is a
    /// real `ConfigWatcher` on paths that never change, so it stays silent.
    @MainActor
    private final class Harness {
        var outcomes: [ConfigChecker.Outcome] = [.valid]
        var checked: [String] = []
        var reloads = 0
        var includes: [String] = []
        var watchedPaths: [[String]] = []
        var statuses: [AutoReloader.Status] = []
        var errors: [AutoReloader.Status] = []
        var logs: [String] = []
        let reloader: AutoReloader

        init(configPath: String = "/cfg/kanata.kbd") {
            let box = Box()
            reloader = AutoReloader(configPath: configPath, dependencies: .init(
                check: { path in
                    await MainActor.run {
                        guard let h = box.harness else { return .failed("gone") }
                        h.checked.append(path)
                        return h.outcomes.count > 1 ? h.outcomes.removeFirst() : h.outcomes[0]
                    }
                },
                reload: { box.harness?.reloads += 1 },
                includedPaths: { box.harness?.includes ?? [] },
                makeWatcher: { paths, onChange in
                    box.harness?.watchedPaths.append(paths)
                    return ConfigWatcher(paths: paths, debounce: 0.01, onChange: onChange)
                }
            ))
            box.harness = self
            reloader.onStatusChange = { [weak self] in self?.statuses.append($0) }
            reloader.onEnterError = { [weak self] in self?.errors.append($0) }
            reloader.log = { [weak self] in self?.logs.append($0) }
        }

        /// Breaks the init cycle: closures capture the box, the box points back here.
        @MainActor final class Box { weak var harness: Harness? }

        func save(_ path: String = "/cfg/kanata.kbd") { reloader.fileChanged(.init(triggeredPaths: [path])) }

        /// Spins the main run loop until the in-flight check has been handled.
        func settle() async {
            for _ in 0..<50 where reloader.status == .checking {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private func enabledRunning() -> Harness {
        let h = Harness()
        h.reloader.setEnabled(true)
        h.reloader.setKanataRunning(true)
        return h
    }

    // MARK: - Enable / pause

    func testDisabledByDefaultAndSaveIsIgnored() async {
        let h = Harness()
        h.reloader.setKanataRunning(true)
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloader.status, .off)
        XCTAssertEqual(h.checked, [])
        XCTAssertEqual(h.watchedPaths, [])
    }

    func testEnableArmsAndWatchesConfigPlusIncludes() {
        let h = Harness()
        h.includes = ["/cfg/extra.kbd"]
        h.reloader.setEnabled(true)
        XCTAssertEqual(h.reloader.status, .armed)
        XCTAssertEqual(h.watchedPaths, [], "no watcher until kanata runs")
        h.reloader.setKanataRunning(true)
        XCTAssertEqual(h.watchedPaths, [["/cfg/kanata.kbd", "/cfg/extra.kbd"]])
    }

    func testStoppingKanataPausesWatcherAndKeepsStatus() async {
        let h = enabledRunning()
        h.outcomes = [.invalid(summary: "bad", details: "")]
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloader.status, .invalid(summary: "bad"))

        h.reloader.setKanataRunning(false)
        XCTAssertEqual(h.reloader.status, .invalid(summary: "bad"), "status survives a stop")
        h.save()
        await h.settle()
        XCTAssertEqual(h.checked.count, 1, "saves while kanata is stopped are ignored")

        h.reloader.setKanataRunning(true)
        XCTAssertEqual(h.watchedPaths.count, 2, "watcher re-created on resume")
    }

    func testDisableClearsStatus() async {
        let h = enabledRunning()
        h.outcomes = [.invalid(summary: "bad", details: "")]
        h.save()
        await h.settle()
        h.reloader.setEnabled(false)
        XCTAssertEqual(h.reloader.status, .off)
        XCTAssertFalse(h.reloader.isEnabled)
    }

    // MARK: - Happy path

    func testValidSaveReloadsAndWaitsForResult() async {
        let h = enabledRunning()
        h.save("/cfg/kanata.kbd")
        XCTAssertEqual(h.reloader.status, .checking)
        await h.settle()
        XCTAssertEqual(h.checked, ["/cfg/kanata.kbd"])
        XCTAssertEqual(h.reloads, 1)
        XCTAssertEqual(h.reloader.status, .reloading)

        h.reloader.reloadResult(ok: true, timedOut: false)
        guard case .reloaded = h.reloader.status else { return XCTFail("expected reloaded, got \(h.reloader.status)") }
        XCTAssertEqual(h.errors, [])
        XCTAssertTrue(h.logs.contains { $0.contains("changed /cfg/kanata.kbd") })
    }

    func testConfigFileReloadEventAlsoCompletes() async {
        let h = enabledRunning()
        h.save()
        await h.settle()
        h.reloader.configReloaded()
        guard case .reloaded = h.reloader.status else { return XCTFail("expected reloaded") }
        // A late ReloadResult must not disturb the settled state.
        h.reloader.reloadResult(ok: false, timedOut: false)
        guard case .reloaded = h.reloader.status else { return XCTFail("late result changed status") }
    }

    func testIncludeListIsRefreshedAfterReload() async {
        let h = enabledRunning()
        XCTAssertEqual(h.watchedPaths, [["/cfg/kanata.kbd"]])
        h.includes = ["/cfg/new.kbd"]
        h.save()
        await h.settle()
        h.reloader.reloadResult(ok: true, timedOut: false)
        XCTAssertEqual(h.watchedPaths.last, ["/cfg/kanata.kbd", "/cfg/new.kbd"])
    }

    // MARK: - Failures

    func testInvalidConfigDoesNotReloadAndNotifiesOnce() async {
        let h = enabledRunning()
        h.outcomes = [.invalid(summary: "kanata.kbd:2:1: Layer base has 1 item(s)", details: "full")]
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloads, 0)
        XCTAssertEqual(h.reloader.status, .invalid(summary: "kanata.kbd:2:1: Layer base has 1 item(s)"))
        XCTAssertEqual(h.errors.count, 1)

        // Second failing save: status updates, no second error transition.
        h.outcomes = [.invalid(summary: "other", details: "")]
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloader.status, .invalid(summary: "other"))
        XCTAssertEqual(h.errors.count, 1)

        // Recovery: reload happens, no notification.
        h.outcomes = [.valid]
        h.save()
        await h.settle()
        h.reloader.reloadResult(ok: true, timedOut: false)
        XCTAssertEqual(h.reloads, 1)
        XCTAssertEqual(h.errors.count, 1)

        // Breaking it again is a new transition.
        h.outcomes = [.invalid(summary: "again", details: "")]
        h.save()
        await h.settle()
        XCTAssertEqual(h.errors.count, 2)
    }

    func testKanataReloadFailureIsAnError() async {
        let h = enabledRunning()
        h.save()
        await h.settle()
        h.reloader.reloadResult(ok: false, timedOut: true)
        XCTAssertEqual(h.reloader.status, .reloadFailed)
        XCTAssertEqual(h.errors, [.reloadFailed])
    }

    func testCheckerUnavailableReloadsAnyway() async {
        let h = enabledRunning()
        h.outcomes = [.failed("no binary")]
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloads, 1)
        XCTAssertEqual(h.reloader.status, .reloading)
    }

    func testSaveDuringReloadRestartsTheCycle() async {
        let h = enabledRunning()
        h.save()
        await h.settle()
        XCTAssertEqual(h.reloader.status, .reloading)
        h.save()
        XCTAssertEqual(h.reloader.status, .checking)
        await h.settle()
        XCTAssertEqual(h.reloads, 2)
    }

    // MARK: - Badge text

    func testAutoBadgeText() {
        XCTAssertNil(AppDelegate.autoBadge(for: .off, label: "auto"))
        XCTAssertEqual(AppDelegate.autoBadge(for: .invalid(summary: "x"), label: "auto"), "auto ⚠")
        XCTAssertEqual(AppDelegate.autoBadge(for: .reloadFailed, label: "auto"), "auto ⚠")
        // Steady `auto` on every non-error state — success is silent, no transient flicker.
        for status: AutoReloader.Status in [.armed, .checking, .reloading, .reloaded(Date())] {
            XCTAssertEqual(AppDelegate.autoBadge(for: status, label: "auto"), "auto", "\(status)")
        }
    }

    // MARK: - Banner suppression (ReloadResult vs ConfigFileReload order)

    func testConfigReloadedReportsAutomaticRegardlessOfEventOrder() async {
        // ReloadResult lands before ConfigFileReload (the order seen on real hardware).
        let a = enabledRunning()
        a.save(); await a.settle()
        XCTAssertEqual(a.reloader.status, .reloading)
        a.reloader.reloadResult(ok: true, timedOut: false)
        XCTAssertTrue(a.reloader.configReloaded(),
                      "auto reload must read as automatic even when ReloadResult landed first")

        // ConfigFileReload lands before ReloadResult.
        let b = enabledRunning()
        b.save(); await b.settle()
        XCTAssertEqual(b.reloader.status, .reloading)
        XCTAssertTrue(b.reloader.configReloaded(),
                      "auto reload must read as automatic when ConfigFileReload landed first")

        // A manual reload (no auto cycle in flight) must keep its banner.
        let c = enabledRunning()
        XCTAssertEqual(c.reloader.status, .armed)
        XCTAssertFalse(c.reloader.configReloaded(), "a manual reload while armed is not suppressed")
    }
}
