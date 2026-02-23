import Foundation

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

let helperDelegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: HelperConfig.machServiceName)
listener.delegate = helperDelegate
listener.resume()
RunLoop.current.run()
