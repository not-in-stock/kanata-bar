import Foundation
import Security

/// Launches kanata via `AuthorizationExecuteWithPrivileges` (system password dialog).
///
/// Start prompts once; Stop is **privilege-free** — the root wrapper polls a
/// user-owned stop sentinel and SIGKILLs kanata (via its EXIT trap) when the file
/// disappears, the app dies, or kanata exits. So neither Stop nor Quit makes a
/// second AuthExec call, which previously re-prompted for a password once the
/// ~5-min authorization cache expired (and silently failed if dismissed). Mirrors
/// `SudoLauncher`'s sentinel design.
@MainActor
class AuthExecLauncher: KanataLauncher {
    nonisolated let binaryPath: String
    nonisolated let configPath: String
    nonisolated let port: UInt16
    nonisolated let extraArgs: [String]
    nonisolated let logURL: URL?

    private var authRef: AuthorizationRef?
    private var authExecPipe: UnsafeMutablePointer<FILE>?
    private var processSource: DispatchSourceProcess?
    private var monitoredPID: Int32 = -1
    private var isStarting = false

    var onEvent: ((LauncherEvent) -> Void)?

    // AuthorizationExecuteWithPrivileges loaded via dlsym (unavailable in Swift SDK)
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    nonisolated private static let authExecFn: AuthExecFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            return nil
        }
        return unsafeBitCast(sym, to: AuthExecFn.self)
    }()

    init(binaryPath: String, configPath: String, port: UInt16, extraArgs: [String], logURL: URL?) {
        self.binaryPath = binaryPath
        self.configPath = configPath
        self.port = port
        self.extraArgs = extraArgs
        self.logURL = logURL
    }

    // MARK: - Start

    func start() {
        // Re-entrancy guard: a second start() would null the in-flight task's
        // pipe/authRef from under it and end up tracking one of two kanatas.
        guard !isStarting else { return }
        isStarting = true

        // Close pipe from previous run
        if let oldPipe = authExecPipe {
            fclose(oldPipe)
            authExecPipe = nil
        }
        if let oldAuth = authRef {
            AuthorizationFree(oldAuth, [])
            authRef = nil
        }

        let binaryPath = binaryPath
        let configPath = configPath
        let port = port
        let extraArgs = extraArgs
        let logURL = logURL

        Task.detached { [weak self] in
            killLeftoverKanata()

            let result = Self.authorize(binaryPath: binaryPath, configPath: configPath, port: port, extraArgs: extraArgs, logURL: logURL)

            switch result {
            case .started(let auth, let pipe, let pid):
                // Ownership transfer of C pointers to MainActor — safe, single producer/consumer
                nonisolated(unsafe) let auth = auth
                nonisolated(unsafe) let pipe = pipe
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.authRef = auth
                    self.authExecPipe = pipe
                    self.monitoredPID = pid
                    self.finishStart(.started(pid: pid))
                    self.startProcessMonitor(pid: pid)
                }

            case .authFailed(let auth):
                if let auth { AuthorizationFree(auth, []) }
                await MainActor.run { [weak self] in self?.finishStart(.failed) }

            case .error(let message):
                await MainActor.run { [weak self] in self?.finishStart(.error(message)) }

            case .noPID(let pipe):
                fclose(pipe)
                await MainActor.run { [weak self] in self?.finishStart(.failed) }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        // Delete the sentinel → the root wrapper's poll loop exits → its EXIT trap
        // SIGKILLs kanata. Privilege-free: no second AuthExec call, so no password
        // re-prompt after the ~5-min authorization cache has expired (the old path
        // re-prompted and silently did nothing if the user dismissed it).
        StopSentinel.remove()
    }

    // MARK: - Cleanup

    func cleanup() {
        if let pipe = authExecPipe {
            fclose(pipe)
            authExecPipe = nil
        }

        // The wrapper reaps kanata on app exit via its app-pid poll; deleting the
        // sentinel is the explicit backstop. No AuthExec kill here — that re-prompted
        // for a password on quit once the auth cache had expired.
        StopSentinel.remove()

        if let auth = authRef {
            AuthorizationFree(auth, [])
            authRef = nil
        }

        processSource?.cancel()
        processSource = nil
        monitoredPID = -1
    }

    // MARK: - Process Monitor

    private func startProcessMonitor(pid: Int32) {
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.processSource = nil
            self.monitoredPID = -1
            self.onEvent?(.exited(code: 1))
        }
        source.resume()
        processSource = source

        // Safety net: if the process exited before kevent registration,
        // the event handler will never fire. Detect this immediately.
        if !isProcessAlive(pid) {
            processSource?.cancel()
            processSource = nil
            monitoredPID = -1
            onEvent?(.exited(code: 1))
        }
    }

    // MARK: - Authorization (blocking, runs off MainActor)

    // C pointers are not Sendable, but we transfer ownership (single producer → single consumer)
    private enum AuthResult: @unchecked Sendable {
        case started(AuthorizationRef, UnsafeMutablePointer<FILE>, Int32)
        case authFailed(AuthorizationRef?)
        case error(String)
        case noPID(UnsafeMutablePointer<FILE>)
    }

    nonisolated private static func authorize(
        binaryPath: String, configPath: String, port: UInt16,
        extraArgs: [String], logURL: URL?
    ) -> AuthResult {
        // Create authorization reference
        var newAuthRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &newAuthRef) == errAuthorizationSuccess,
              let auth = newAuthRef else {
            return .error("failed to create authorization")
        }

        // Request admin rights (shows system password dialog)
        var rights = AuthorizationRights(count: 0, items: nil)
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
        let status = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
        guard status == errAuthorizationSuccess else {
            return .authFailed(auth)
        }

        guard let authExec = authExecFn else {
            AuthorizationFree(auth, [])
            return .error("AuthorizationExecuteWithPrivileges unavailable")
        }

        // Wrap kanata in a shell that kills it when our app exits.
        let appPID = ProcessInfo.processInfo.processIdentifier
        let kanataArgs = ([binaryPath, "-c", configPath, "--port", "\(port)"] + extraArgs)
            .map { shellEscape($0) }
            .joined(separator: " ")

        var logRedirect = ""
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logRedirect = " > \(shellEscape(logURL.path)) 2>&1"
        }

        // Create the stop sentinel the wrapper polls (see `makeWrapperScript`), so
        // Stop/Quit can reap kanata by deleting it — no second AuthExec call.
        StopSentinel.create()
        let script = makeWrapperScript(kanataCommand: "\(kanataArgs)\(logRedirect)", appPID: appPID, sentinelPath: StopSentinel.path)

        let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(script), nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }

        var commPipe: UnsafeMutablePointer<FILE>?
        let execStatus = cArgs.withUnsafeBufferPointer { buf in
            "/bin/sh".withCString { pathPtr in
                authExec(auth, pathPtr, AuthorizationFlags(), buf.baseAddress!, &commPipe)
            }
        }

        guard execStatus == errAuthorizationSuccess, let pipe = commPipe else {
            AuthorizationFree(auth, [])
            return .authFailed(nil)
        }

        // Read kanata PID from the shell wrapper (first line of output)
        var pidLine = ""
        while true {
            let c = fgetc(pipe)
            if c == EOF { break }
            let ch = Character(UnicodeScalar(UInt8(c)))
            if ch == "\n" { break }
            pidLine.append(ch)
        }

        if let pid = Int32(pidLine), pid > 0 {
            return .started(auth, pipe, pid)
        } else {
            return .noPID(pipe)
        }
    }

    // MARK: - Helpers

    nonisolated static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Terminal point of every start() path: clears the re-entrancy flag, then
    /// reports the outcome. All start outcomes must go through here.
    private func finishStart(_ event: LauncherEvent) {
        isStarting = false
        onEvent?(event)
    }

    /// Root wrapper: launches kanata, reports its pid, then exits as soon as
    /// kanata dies, the app dies, OR the stop sentinel is deleted. SIGKILL because
    /// kanata ignores SIGTERM; 200ms poll caps the window between kanata-bar dying
    /// and kanata being killed. Watching `$KPID` too keeps the wrapper from
    /// outliving a stopped kanata (whose EXIT trap would later fire on a recycled
    /// pid); watching the sentinel makes `stop()` privilege-free. Shared verbatim by
    /// `SudoLauncher`.
    nonisolated static func makeWrapperScript(kanataCommand: String, appPID: Int32, sentinelPath: String) -> String {
        let escSentinel = shellEscape(sentinelPath)
        return "\(kanataCommand) & KPID=$!; echo $KPID; "
            + "trap 'kill -KILL $KPID 2>/dev/null' EXIT; "
            + "while kill -0 $KPID 2>/dev/null && kill -0 \(appPID) 2>/dev/null && [ -e \(escSentinel) ]; do sleep 0.2; done"
    }
}
