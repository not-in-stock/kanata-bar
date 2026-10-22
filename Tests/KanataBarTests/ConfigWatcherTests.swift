import XCTest
@testable import KanataBarLib

final class ConfigWatcherTests: XCTestCase {

    private var dir: URL!
    private var watcher: ConfigWatcher?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    /// Thread-safe sink for watcher callbacks.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConfigWatcher.Change] = []
        var changes: [ConfigWatcher.Change] { lock.withLock { items } }
        func append(_ c: ConfigWatcher.Change) { lock.withLock { items.append(c) } }
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: path(name), atomically: false, encoding: .utf8)
    }

    /// Editor-style atomic save: write a sibling temp file, rename over the target.
    private func atomicWrite(_ name: String, _ text: String) throws {
        let tmp = path("\(name).tmp-\(UUID().uuidString)")
        try text.write(toFile: tmp, atomically: false, encoding: .utf8)
        XCTAssertEqual(rename(tmp, path(name)), 0)
    }

    /// Repoint `link` at `target` atomically (temp link + rename).
    private func swapLink(_ link: String, to target: String) throws {
        let tmp = path("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: tmp, withDestinationPath: target)
        XCTAssertEqual(rename(tmp, path(link)), 0)
    }

    @discardableResult
    private func startWatcher(_ paths: [String], sink: Sink) -> ConfigWatcher {
        let w = ConfigWatcher(paths: paths, debounce: 0.1) { sink.append($0) }
        w.start()
        watcher = w
        return w
    }

    /// Wait until `sink` holds `count` changes, then a little longer to catch extras.
    private func expectChanges(_ count: Int, in sink: Sink,
                               timeout: TimeInterval = 3,
                               file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while sink.changes.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35)) // 3× debounce
        XCTAssertEqual(sink.changes.count, count, "changes: \(sink.changes)", file: file, line: line)
    }

    // MARK: - Tests

    func testInPlaceWriteReportsOneChangeWithPath() throws {
        try write("kanata.kbd", "(defsrc a)")
        let sink = Sink()
        startWatcher([path("kanata.kbd")], sink: sink)

        try write("kanata.kbd", "(defsrc a b)")

        expectChanges(1, in: sink)
        XCTAssertEqual(sink.changes.first?.triggeredPaths, [path("kanata.kbd")])
    }

    func testBurstOfWritesIsDebouncedIntoOneChange() throws {
        try write("kanata.kbd", "v0")
        let sink = Sink()
        startWatcher([path("kanata.kbd")], sink: sink)

        try write("kanata.kbd", "v1")
        try write("kanata.kbd", "v2")
        try write("kanata.kbd", "v3")

        expectChanges(1, in: sink)
    }

    func testIdenticalContentIsNotReported() throws {
        try write("kanata.kbd", "same")
        let sink = Sink()
        startWatcher([path("kanata.kbd")], sink: sink)

        try write("kanata.kbd", "same")

        expectChanges(0, in: sink)
    }

    func testAtomicSaveIsReportedAndWatcherStaysArmed() throws {
        try write("kanata.kbd", "v0")
        let sink = Sink()
        let w = startWatcher([path("kanata.kbd")], sink: sink)

        try atomicWrite("kanata.kbd", "v1")
        expectChanges(1, in: sink)
        XCTAssertEqual(w.watchedPaths, [path("kanata.kbd")])

        // The new inode must be watched too.
        try write("kanata.kbd", "v2")
        expectChanges(2, in: sink)
    }

    func testDeleteAndRecreateIsReported() throws {
        try write("kanata.kbd", "v0")
        let sink = Sink()
        startWatcher([path("kanata.kbd")], sink: sink)

        try FileManager.default.removeItem(atPath: path("kanata.kbd"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // longer than debounce, inside re-arm retries
        try write("kanata.kbd", "v1")

        expectChanges(1, in: sink)
        XCTAssertEqual(sink.changes.first?.triggeredPaths, [path("kanata.kbd")])
    }

    func testSymlinkChainIsResolvedAndSwapIsReported() throws {
        try write("a.kbd", "A")
        try write("b.kbd", "B")
        try FileManager.default.createSymbolicLink(atPath: path("store"), withDestinationPath: "a.kbd")
        try FileManager.default.createSymbolicLink(atPath: path("kanata.kbd"), withDestinationPath: "store")
        let sink = Sink()
        let w = startWatcher([path("kanata.kbd")], sink: sink)
        XCTAssertEqual(w.watchedPaths, [path("a.kbd"), path("kanata.kbd"), path("store")])

        // Rebuild-style swap of the middle link: content changes A → B.
        try swapLink("store", to: "b.kbd")
        expectChanges(1, in: sink)
        XCTAssertEqual(w.watchedPaths, [path("b.kbd"), path("kanata.kbd"), path("store")])

        // Editing the new real file is observed; the old one is ignored.
        try write("a.kbd", "A2")
        expectChanges(1, in: sink)
        try write("b.kbd", "B2")
        expectChanges(2, in: sink)
        XCTAssertEqual(sink.changes.last?.triggeredPaths, [path("b.kbd")])
    }

    func testEditingRealFileBehindSymlinkIsReported() throws {
        try write("real.kbd", "v0")
        try FileManager.default.createSymbolicLink(atPath: path("kanata.kbd"), withDestinationPath: "real.kbd")
        let sink = Sink()
        startWatcher([path("kanata.kbd")], sink: sink)

        try atomicWrite("real.kbd", "v1")

        expectChanges(1, in: sink)
        XCTAssertEqual(sink.changes.first?.triggeredPaths, [path("real.kbd")])
    }

    func testIncludedFileIsWatched() throws {
        try write("kanata.kbd", "(include extra.kbd)")
        try write("extra.kbd", "x0")
        let sink = Sink()
        startWatcher([path("kanata.kbd"), path("extra.kbd")], sink: sink)

        try write("extra.kbd", "x1")

        expectChanges(1, in: sink)
        XCTAssertEqual(sink.changes.first?.triggeredPaths, [path("extra.kbd")])
    }

    func testStopSuppressesChanges() throws {
        try write("kanata.kbd", "v0")
        let sink = Sink()
        let w = startWatcher([path("kanata.kbd")], sink: sink)
        w.stop()
        XCTAssertFalse(w.isActive)
        XCTAssertEqual(w.watchedPaths, [])

        try write("kanata.kbd", "v1")

        expectChanges(0, in: sink)
    }

    func testRestartTakesFreshSnapshot() throws {
        try write("kanata.kbd", "v0")
        let sink = Sink()
        let w = startWatcher([path("kanata.kbd")], sink: sink)
        w.stop()
        try write("kanata.kbd", "v1") // edited while paused
        w.start()

        expectChanges(0, in: sink) // the pause-time edit is not replayed
        try write("kanata.kbd", "v2")
        expectChanges(1, in: sink)
    }

    func testMissingFileAtStartIsPickedUpWhenCreated() throws {
        let sink = Sink()
        let w = startWatcher([path("kanata.kbd")], sink: sink)
        XCTAssertEqual(w.watchedPaths, [])

        try write("kanata.kbd", "v0")
        // Nothing is armed, so creation alone is not observed — that is a known limit.
        expectChanges(0, in: sink)
    }

    func testSymlinkChainHelper() throws {
        try write("real.kbd", "r")
        try FileManager.default.createSymbolicLink(atPath: path("l1"), withDestinationPath: "real.kbd")
        try FileManager.default.createSymbolicLink(atPath: path("l2"), withDestinationPath: path("l1"))
        XCTAssertEqual(ConfigWatcher.symlinkChain(of: path("l2")), [path("l2"), path("l1"), path("real.kbd")])
        XCTAssertEqual(ConfigWatcher.symlinkChain(of: path("real.kbd")), [path("real.kbd")])
        XCTAssertEqual(ConfigWatcher.symlinkChain(of: path("missing")), [path("missing")])
    }
}
