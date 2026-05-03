import Foundation
import Security
import Shared

class HelperTool: NSObject, HelperProtocol {
    func sendSignal(_ sig: Int32, toProcessID pid: Int32, withReply reply: @escaping (Bool, String) -> Void) {
        guard pid > 0 else {
            reply(false, "invalid pid")
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
        reply(kill(pid, 0) == 0)
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    let tool = HelperTool()
    let requirement: String?

    init(requirement: String?) {
        self.requirement = requirement
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
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
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
