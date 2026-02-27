import Foundation
import Security

/// Launches kanata via `AuthorizationExecuteWithPrivileges` (system password dialog).
/// Uses a shell wrapper that kills kanata when the app exits.
class AuthExecLauncher: KanataLauncher {
    private let binaryPath: String
    private let configPath: String
    private let port: UInt16
    private let extraArgs: [String]
    private let logURL: URL?

    private var authRef: AuthorizationRef?
    private var authExecPipe: UnsafeMutablePointer<FILE>?
    private var processMonitorWork: DispatchWorkItem?
    private var monitoredPID: Int32 = -1

    var onStarted: ((Int32) -> Void)?
    var onExited: ((Int32) -> Void)?
    var onFailure: (() -> Void)?
    var onError: ((String) -> Void)?

    // AuthorizationExecuteWithPrivileges loaded via dlsym (unavailable in Swift SDK)
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let authExecFn: AuthExecFn? = {
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
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            killLeftoverKanata()

            // Close pipe from previous run
            if let oldPipe = authExecPipe {
                fclose(oldPipe)
                authExecPipe = nil
            }
            if let oldAuth = authRef {
                AuthorizationFree(oldAuth, [])
                authRef = nil
            }

            // Create authorization reference
            var newAuthRef: AuthorizationRef?
            guard AuthorizationCreate(nil, nil, [], &newAuthRef) == errAuthorizationSuccess,
                  let auth = newAuthRef else {
                DispatchQueue.main.async {
                    self.onError?("failed to create authorization")
                }
                return
            }

            // Request admin rights (shows system password dialog)
            var rights = AuthorizationRights(count: 0, items: nil)
            let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
            let status = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            guard status == errAuthorizationSuccess else {
                AuthorizationFree(auth, [])
                DispatchQueue.main.async {
                    self.onFailure?()
                }
                return
            }

            guard let authExec = Self.authExecFn else {
                AuthorizationFree(auth, [])
                DispatchQueue.main.async {
                    self.onError?("AuthorizationExecuteWithPrivileges unavailable")
                }
                return
            }

            // Wrap kanata in a shell that kills it when our app exits.
            let appPID = ProcessInfo.processInfo.processIdentifier
            let kanataArgs = ([binaryPath, "-c", configPath, "--port", "\(port)"] + extraArgs)
                .map { Self.shellEscape($0) }
                .joined(separator: " ")

            var logRedirect = ""
            if let logURL {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                logRedirect = " > \(Self.shellEscape(logURL.path)) 2>&1"
            }

            let script = "\(kanataArgs)\(logRedirect) & KPID=$!; echo $KPID; trap 'kill $KPID 2>/dev/null' EXIT; while kill -0 \(appPID) 2>/dev/null; do sleep 1; done"

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
                DispatchQueue.main.async {
                    self.onFailure?()
                }
                return
            }

            authRef = auth
            authExecPipe = pipe

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
                DispatchQueue.main.async {
                    self.monitoredPID = pid
                    self.onStarted?(pid)
                    self.startProcessMonitor(pid: pid)
                }
            } else {
                fclose(pipe)
                authExecPipe = nil
                DispatchQueue.main.async {
                    self.onFailure?()
                }
            }
        }
    }

    // MARK: - Stop

    func stop() {
        let pid = monitoredPID
        guard pid > 0 else { return }
        killViaAuthExec(signal: "TERM", pid: pid)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard isProcessAlive(pid) else { return }
            self?.killViaAuthExec(signal: "KILL", pid: pid)
        }
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
            usleep(500_000)
        }

        if let auth = authRef {
            AuthorizationFree(auth, [])
            authRef = nil
        }

        processMonitorWork?.cancel()
        processMonitorWork = nil
        monitoredPID = -1
    }

    // MARK: - Process Monitor

    private func startProcessMonitor(pid: Int32) {
        guard pid > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.monitoredPID == pid else { return }
            if !isProcessAlive(pid) {
                DispatchQueue.main.async {
                    self.processMonitorWork = nil
                    self.monitoredPID = -1
                    self.onExited?(1)
                }
                return
            }
            self.startProcessMonitor(pid: pid)
        }
        processMonitorWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: work)
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

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
