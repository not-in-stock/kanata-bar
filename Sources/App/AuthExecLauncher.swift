import Foundation
import Security

/// Launches kanata via `AuthorizationExecuteWithPrivileges` (system password dialog).
/// Uses a shell wrapper that kills kanata when the app exits.
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
                    self.onEvent?(.started(pid: pid))
                    self.startProcessMonitor(pid: pid)
                }

            case .authFailed(let auth):
                if let auth { AuthorizationFree(auth, []) }
                await MainActor.run { [weak self] in self?.onEvent?(.failed) }

            case .error(let message):
                await MainActor.run { [weak self] in self?.onEvent?(.error(message)) }

            case .noPID(let pipe):
                fclose(pipe)
                await MainActor.run { [weak self] in self?.onEvent?(.failed) }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        let pid = monitoredPID
        guard pid > 0 else { return }
        // kanata on macOS ignores SIGTERM/SIGINT (no signal handlers) and
        // AuthExec I/O goes to file, so pipe-break is impossible — SIGKILL is the only option.
        killViaAuthExec(signal: "KILL", pid: pid)
    }

    // MARK: - Cleanup

    func cleanup() {
        if let pipe = authExecPipe {
            fclose(pipe)
            authExecPipe = nil
        }

        let pid = monitoredPID
        if pid > 0, let auth = authRef, let authExec = Self.authExecFn {
            let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("-KILL"), strdup("\(pid)"), nil]
            defer { cArgs.forEach { if let p = $0 { free(p) } } }
            cArgs.withUnsafeBufferPointer { buf in
                "/bin/kill".withCString { pathPtr in
                    _ = authExec(auth, pathPtr, AuthorizationFlags(), buf.baseAddress!, nil)
                }
            }
            usleep(Timing.cleanupGracePeriod)
        }

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

        let script = "\(kanataArgs)\(logRedirect) & KPID=$!; echo $KPID; "
            + "trap 'kill $KPID 2>/dev/null' EXIT; "
            + "while kill -0 \(appPID) 2>/dev/null; do sleep 1; done"

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

    private func killViaAuthExec(signal: String, pid: Int32) {
        guard let auth = authRef, let authExec = Self.authExecFn else { return }
        let cArgs: [UnsafeMutablePointer<CChar>?] = [strdup("-\(signal)"), strdup("\(pid)"), nil]
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        cArgs.withUnsafeBufferPointer { buf in
            "/bin/kill".withCString { pathPtr in
                _ = authExec(auth, pathPtr, AuthorizationFlags(), buf.baseAddress!, nil)
            }
        }
    }

    nonisolated static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
