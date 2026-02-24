import AppKit

extension AppDelegate {
    var appLogURL: URL {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent("kanata-bar.log")
    }

    var kanataLogURL: URL {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        return logsDir.appendingPathComponent("kanata.log")
    }

    func log(_ message: String) {
        let entry = "\(logTimestamp()) \(message)\n"
        print("kanata-bar: \(message)")
        appendToFile(appLogURL, entry)
    }

    @objc func doViewAppLog() {
        openInConsole(appLogURL)
    }

    @objc func doViewKanataLog() {
        openInConsole(kanataLogURL)
    }

    private func openInConsole(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open([url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func logTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    func appendToFile(_ url: URL, _ entry: String) {
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
