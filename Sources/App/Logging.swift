import AppKit
import Shared

enum Logging {
    static let appLogURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent(Constants.Log.appFilename)
    }()

    static let kanataLogURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent(Constants.Log.kanataFilename)
    }()

    static func log(_ message: String) {
        let entry = "\(timestamp()) \(message)\n"
        print("kanata-bar: \(message)")
        appendToFile(appLogURL, entry)
    }

    static func truncateLog() {
        FileManager.default.createFile(atPath: appLogURL.path, contents: nil)
    }

    static func openInConsole(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open([url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func appendToFile(_ url: URL, _ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}
