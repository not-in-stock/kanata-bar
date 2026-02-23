import Foundation

@objc protocol HelperProtocol {
    /// Send a signal to a process (helper runs as root, can signal any process)
    func sendSignal(_ sig: Int32, toProcessID pid: Int32, withReply reply: @escaping (Bool, String) -> Void)

    /// Check if a process is alive
    func isProcessAlive(_ pid: Int32, withReply reply: @escaping (Bool) -> Void)
}
