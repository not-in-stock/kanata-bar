import Foundation

// Minimal privileged helper — provides root-level process operations via XPC.
// Does NOT start kanata itself (TCC requires user session context for that).

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
        // kill with signal 0 checks if process exists without sending a signal
        reply(kill(pid, 0) == 0)
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    let tool = HelperTool()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = tool
        connection.resume()
        return true
    }
}

@main
enum HelperMain {
    static func main() {
        let delegate = HelperDelegate()
        let listener = NSXPCListener(machServiceName: "com.kanata-bar.test-helper")
        listener.delegate = delegate
        listener.resume()

        let msg = "helper started: uid=\(getuid()), pid=\(getpid()), time=\(Date())\n"
        FileManager.default.createFile(atPath: "/tmp/kanata-bar-helper.log", contents: msg.data(using: .utf8))

        RunLoop.current.run()
    }
}
