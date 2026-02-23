import Foundation

enum HelperConfig {
    static let machServiceName = "com.kanata-bar.helper"
}

@objc protocol HelperProtocol {
    func sendSignal(_ sig: Int32, toProcessID pid: Int32, withReply reply: @escaping (Bool, String) -> Void)
    func isProcessAlive(_ pid: Int32, withReply reply: @escaping (Bool) -> Void)
}
