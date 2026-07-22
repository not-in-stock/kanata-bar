import Darwin
import Foundation
import Security
import Shared

private let kProcPathMax: Int = 4 * 1024

private func helperLog(_ message: String) {
    FileHandle.standardError.write(Data("kanata-bar-helper: \(message)\n".utf8))
}

/// Owns a single supervised kanata child. Serial-queue guarded so the XPC
/// exported-object callbacks (delivered on an internal queue) can't race on the
/// child state. Uses `Process` so the child is reaped automatically and its exit
/// clears the single-child guard.
final class KanataSupervisor {
    private let queue = DispatchQueue(label: "com.kanata-bar.helper.supervisor")
    private var child: Process?

    /// Launch kanata. Returns the child pid, or -1 and an error message.
    func start(path: String, args: [String], log: FileHandle?) -> (pid: Int32, message: String) {
        queue.sync {
            if let child, child.isRunning {
                return (-1, "kanata already running (pid \(child.processIdentifier))")
            }
            // Phase-1 trust: same basename rule as sendSignal. Real cdhash consent
            // is phase 2 — do not widen this without it.
            guard (path as NSString).lastPathComponent == Constants.kanataBinaryName else {
                return (-1, "refusing to launch non-kanata binary \(path)")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice
            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.queue.async {
                    if self.child === proc { self.child = nil }
                }
                helperLog("kanata exited (status \(proc.terminationStatus))")
            }

            do {
                try process.run()
                child = process
                let pid = process.processIdentifier
                helperLog("launched kanata pid \(pid): \(path) \(args.joined(separator: " "))")
                return (pid, "started")
            } catch {
                return (-1, "launch failed: \(error.localizedDescription)")
            }
        }
    }

    /// SIGKILL the current child, if any. Returns whether one was running.
    func stop(reason: String) -> (stopped: Bool, message: String) {
        queue.sync {
            guard let child, child.isRunning else { return (false, "no kanata child running") }
            let pid = child.processIdentifier
            helperLog("killing kanata pid \(pid): \(reason)")
            kill(pid, SIGKILL)
            return (true, "SIGKILL sent to pid \(pid)")
        }
    }
}

class HelperTool: NSObject, HelperProtocol {
    let supervisor: KanataSupervisor

    init(supervisor: KanataSupervisor) {
        self.supervisor = supervisor
    }

    func startKanata(path: String, args: [String], log: FileHandle?,
                     withReply reply: @escaping (Int32, String) -> Void) {
        let result = supervisor.start(path: path, args: args, log: log)
        // Tie the child's lifetime to the app connection that started it: if the
        // app dies (even `kill -9`), that connection invalidates and we SIGKILL
        // kanata — closing the "kanata outlives the app" bug at the root.
        if result.pid > 0, let connection = NSXPCConnection.current() {
            let supervisor = supervisor
            connection.invalidationHandler = {
                _ = supervisor.stop(reason: "app XPC connection invalidated")
            }
        }
        reply(result.pid, result.message)
    }

    func stopKanata(withReply reply: @escaping (Bool, String) -> Void) {
        let result = supervisor.stop(reason: "stopKanata requested")
        reply(result.stopped, result.message)
    }

    func sendSignal(_ sig: Int32, toProcessID pid: Int32, withReply reply: @escaping (Bool, String) -> Void) {
        guard pid > 1 else {
            reply(false, "invalid pid")
            return
        }
        guard let path = executablePath(forPID: pid) else {
            reply(false, "pid \(pid) not found")
            return
        }
        let basename = (path as NSString).lastPathComponent
        guard basename == Constants.kanataBinaryName else {
            reply(false, "pid \(pid) is not \(Constants.kanataBinaryName) (\(basename))")
            return
        }
        let result = kill(pid, sig)
        if result == 0 {
            reply(true, "signal \(sig) sent to pid \(pid)")
        } else {
            let err = String(cString: strerror(errno))
            reply(false, "kill(\(pid), \(sig)) failed: \(err)")
        }
    }

    func isProcessAlive(_ pid: Int32, withReply reply: @escaping (Bool) -> Void) {
        guard pid > 1, let path = executablePath(forPID: pid),
              (path as NSString).lastPathComponent == Constants.kanataBinaryName else {
            reply(false)
            return
        }
        reply(kill(pid, 0) == 0)
    }

    /// Returns the absolute path of the executable backing `pid`, or nil if the
    /// process doesn't exist or its path can't be read.
    private func executablePath(forPID pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: kProcPathMax)
        let len = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return proc_pidpath(pid, base, UInt32(ptr.count))
        }
        guard len > 0 else { return nil }
        return String(cString: buf)
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    // One supervisor shared across all connections → one kanata child total.
    let supervisor = KanataSupervisor()
    let tool: HelperTool
    let requirement: String?

    init(requirement: String?) {
        self.requirement = requirement
        self.tool = HelperTool(supervisor: supervisor)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let requirement else {
            FileHandle.standardError.write(Data("kanata-bar-helper: rejecting connection — no signing requirement\n".utf8))
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = HelperInterface.make()
        connection.exportedObject = tool
        connection.resume()
        return true
    }
}

/// Compute the code-signing requirement that incoming XPC clients must satisfy.
///
/// The helper is installed inside the parent app bundle at
/// `<App.app>/Contents/MacOS/kanata-bar-helper`. We walk up to the .app, read
/// its CDHash, and pin it. With ad-hoc signing this is the only way to
/// distinguish "our app" from any other binary signed with the same identifier.
func computeClientRequirement() -> String? {
    let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let execURL = URL(fileURLWithPath: execPath).resolvingSymlinksInPath()
    let appBundle = execURL
        .deletingLastPathComponent()  // MacOS/
        .deletingLastPathComponent()  // Contents/
        .deletingLastPathComponent()  // <App.app>
    guard appBundle.pathExtension == "app" else { return nil }

    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(appBundle as CFURL, [], &staticCode) == errSecSuccess,
          let code = staticCode else { return nil }

    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: 0)
    guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let cdhash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }

    let hex = cdhash.map { String(format: "%02x", $0) }.joined()
    return "identifier \"\(Constants.bundleID)\" and cdhash H\"\(hex)\""
}

let requirement = computeClientRequirement()
if requirement == nil {
    FileHandle.standardError.write(Data("kanata-bar-helper: failed to compute client requirement; all connections will be rejected\n".utf8))
}

let helperDelegate = HelperDelegate(requirement: requirement)
let listener = NSXPCListener(machServiceName: HelperConfig.machServiceName)
listener.delegate = helperDelegate
listener.resume()
RunLoop.current.run()
