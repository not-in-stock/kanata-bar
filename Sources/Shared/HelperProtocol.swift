import Foundation

public enum HelperConfig {
    public static let machServiceName = Constants.helperBundleID
}

@objc public protocol HelperProtocol {
    func sendSignal(_ sig: Int32, toProcessID pid: Int32, withReply reply: @escaping (Bool, String) -> Void)
    func isProcessAlive(_ pid: Int32, withReply reply: @escaping (Bool) -> Void)

    /// Supervisor (task 15 phase 1): launch kanata as a child of the root helper.
    ///
    /// The app opens the log file itself and passes an already-open `FileHandle`;
    /// the helper dup2s it onto the child's stdout/stderr and never opens an
    /// app-supplied path as root. Replies with the child pid, or -1 and an error.
    ///
    /// Phase-1 trust is the same basename rule as `sendSignal` — admin-approved
    /// cdhash consent lands in phase 2, so this path stays experimental/off.
    func startKanata(path: String, args: [String], log: FileHandle?,
                     withReply reply: @escaping (Int32, String) -> Void)

    /// Kill the supervised kanata child (SIGKILL — kanata ignores SIGTERM).
    /// Replies whether a child was running and a short status message.
    func stopKanata(withReply reply: @escaping (Bool, String) -> Void)
}

public enum HelperInterface {
    /// Build the XPC interface, whitelisting `FileHandle` for `startKanata`'s
    /// `log` argument so the file descriptor is transported over the connection.
    /// Both the client (`remoteObjectInterface`) and the helper
    /// (`exportedInterface`) must use this so the handle decodes on each side.
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperProtocol.self)
        let sel = #selector(HelperProtocol.startKanata(path:args:log:withReply:))
        let classes = NSSet(array: [FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(classes, for: sel, argumentIndex: 2, ofReply: false)
        return interface
    }
}
