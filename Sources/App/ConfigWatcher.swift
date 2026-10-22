import Foundation

/// Watches a kanata config (and any files it includes) and reports one
/// aggregated change per burst of filesystem activity.
///
/// Independent of kanata and AppKit: give it paths, get `Change` callbacks.
///
/// - Each path's symlink chain is resolved and every link in it is watched
///   with its own kqueue vnode source, so swapping a link (e.g. a Home
///   Manager rebuild) and editing the final file are both observed.
/// - Atomic saves (write temp + rename over) and editors that delete and
///   recreate arrive as rename/delete; the watcher re-resolves the chain,
///   reopens and re-arms, retrying briefly while the file is missing.
/// - Events are debounced; a burst only produces a callback when the
///   content of some watched file actually differs from the last snapshot.
///   A save that leaves every file byte-identical is dropped.
/// - Needs no privacy permission: read access to the file is enough.
final class ConfigWatcher: @unchecked Sendable {

    struct Change: Equatable, Sendable {
        /// Watched paths that signalled during the burst, sorted.
        let triggeredPaths: [String]
    }

    private struct Watched {
        let source: DispatchSourceFileSystemObject
        let fd: Int32
    }

    /// Configured (unresolved) paths: the config and its includes.
    let paths: [String]
    let debounce: TimeInterval

    private let queue = DispatchQueue(label: "kanata-bar.config-watcher")
    private let callbackQueue: DispatchQueue
    private let onChange: @Sendable (Change) -> Void

    // All state below is confined to `queue`.
    private var watched: [String: Watched] = [:]
    private var pendingTriggers: Set<String> = []
    private var pendingWork: DispatchWorkItem?
    private var rearmWork: [String: DispatchWorkItem] = [:]
    private var snapshot: [String: Data] = [:]
    private var active = false

    private static let maxLinkDepth = 32
    private static let rearmRetryInterval: TimeInterval = 0.05
    private static let rearmRetryLimit = 40 // 2 s of a missing file

    init(paths: [String],
         debounce: TimeInterval = 0.3,
         callbackQueue: DispatchQueue = .main,
         onChange: @escaping @Sendable (Change) -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.callbackQueue = callbackQueue
        self.onChange = onChange
    }

    deinit {
        queue.sync { tearDown() }
    }

    // MARK: - Control

    /// Start watching. Takes the initial content snapshot, so the first
    /// callback only fires for a change made after this call.
    func start() {
        queue.sync {
            guard !active else { return }
            active = true
            snapshot = readSnapshot()
            for path in paths { arm(chainOf: path) }
        }
    }

    /// Stop watching and drop any pending (debounced) change.
    func stop() {
        queue.sync { tearDown() }
    }

    var isActive: Bool { queue.sync { active } }

    /// Fully resolved paths currently armed (links and real files). For logs/tests.
    var watchedPaths: [String] { queue.sync { watched.keys.sorted() } }

    // MARK: - Arming (on queue)

    private func tearDown() {
        active = false
        pendingWork?.cancel()
        pendingWork = nil
        pendingTriggers = []
        rearmWork.values.forEach { $0.cancel() }
        rearmWork = [:]
        for entry in watched.values { entry.source.cancel() } // cancel handler closes fd
        watched = [:]
    }

    /// Watch every component of `path`'s symlink chain, including the final file.
    private func arm(chainOf path: String) {
        for link in Self.symlinkChain(of: path) where watched[link] == nil {
            arm(path: link)
        }
    }

    @discardableResult
    private func arm(path: String) -> Bool {
        let fd = open(path, O_EVTONLY | O_SYMLINK)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handle(event: source.data, path: path)
        }
        source.setCancelHandler { close(fd) }
        watched[path] = Watched(source: source, fd: fd)
        source.resume()
        return true
    }

    private func disarm(path: String) {
        watched.removeValue(forKey: path)?.source.cancel()
    }

    private func handle(event: DispatchSource.FileSystemEvent, path: String) {
        guard active else { return }
        pendingTriggers.insert(path)
        if !event.isDisjoint(with: [.rename, .delete, .link]) {
            // The inode we hold is gone or replaced: reopen the whole chain so
            // a swapped link or a new file after an atomic save is tracked.
            disarm(path: path)
            scheduleRearm(attempt: 0)
        }
        scheduleFire()
    }

    /// Re-resolve every configured path and arm whatever is not armed yet.
    /// Retries while a file is momentarily missing (editor mid-save).
    private func scheduleRearm(attempt: Int) {
        let key = "chain"
        rearmWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.rearmWork[key] = nil
            var complete = true
            for path in self.paths {
                let chain = Self.symlinkChain(of: path)
                for link in chain where self.watched[link] == nil {
                    if !self.arm(path: link) { complete = false }
                }
                // The final element must be a real file for the chain to be whole.
                if let last = chain.last, Self.isSymlink(last) || self.watched[last] == nil {
                    complete = false
                }
            }
            self.pruneStaleWatches()
            if !complete, attempt < Self.rearmRetryLimit {
                self.scheduleRearm(attempt: attempt + 1)
            } else {
                self.scheduleFire()
            }
        }
        rearmWork[key] = work
        queue.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : Self.rearmRetryInterval), execute: work)
    }

    /// Drop watches on files that are no longer part of any configured chain
    /// (e.g. the old target after a link swap).
    private func pruneStaleWatches() {
        let live = Set(paths.flatMap(Self.symlinkChain(of:)))
        for path in watched.keys where !live.contains(path) {
            disarm(path: path)
        }
    }

    // MARK: - Debounce + content compare (on queue)

    private func scheduleFire() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func fire() {
        pendingWork = nil
        guard active else { return }
        if rearmWork["chain"] != nil { return } // chain still settling; it will refire
        let triggered = pendingTriggers.sorted()
        pendingTriggers = []
        let current = readSnapshot()
        guard current != snapshot else { return }
        snapshot = current
        let change = Change(triggeredPaths: triggered)
        callbackQueue.async { [onChange] in onChange(change) }
    }

    private func readSnapshot() -> [String: Data] {
        var result: [String: Data] = [:]
        for path in paths {
            result[path] = FileManager.default.contents(atPath: path)
        }
        return result
    }

    // MARK: - Symlink chain

    /// `path`, then each link target in turn, ending at the first non-link
    /// (or the first missing component). Relative targets are resolved
    /// against the link's directory.
    static func symlinkChain(of path: String) -> [String] {
        var chain = [path]
        var current = path
        var depth = 0
        while isSymlink(current), depth < maxLinkDepth,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current) {
            let next = target.hasPrefix("/")
                ? target
                : (current as NSString).deletingLastPathComponent + "/" + target
            current = URL(fileURLWithPath: next).standardizedFileURL.path
            if chain.contains(current) { break }
            chain.append(current)
            depth += 1
        }
        return chain
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}
