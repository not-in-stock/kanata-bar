import XCTest
@testable import KanataBarLib

@MainActor
final class LoginItemTests: XCTestCase {

    // MARK: - isAgentExternal

    func testIsAgentExternalReturnsFalseWhenNoPlist() {
        // Default state: no plist in ~/Library/LaunchAgents/
        // This test assumes the test environment doesn't have a kanata-bar plist
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.isAgentExternal)
    }

    // MARK: - Migration

    func testMigrateRemovesRegularFile() throws {
        let delegate = AppDelegate()
        let dir = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents"
        let plistPath = "\(dir)/com.kanata-bar.plist"

        // Create a regular file simulating old LaunchAgent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "test".write(toFile: plistPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: plistPath) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: plistPath))
        delegate.migrateFromLaunchAgent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistPath))
    }

    func testMigratePreservesSymlink() throws {
        let delegate = AppDelegate()
        let dir = FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/LaunchAgents"
        let plistPath = "\(dir)/com.kanata-bar.plist"

        // Create a symlink simulating nix-darwin managed agent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Clean up any existing file first
        try? FileManager.default.removeItem(atPath: plistPath)
        try FileManager.default.createSymbolicLink(atPath: plistPath, withDestinationPath: "/dev/null")
        defer { try? FileManager.default.removeItem(atPath: plistPath) }

        delegate.migrateFromLaunchAgent()
        // Symlink should NOT be removed
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistPath))
    }

    func testMigrateNoOpWhenNoPlist() {
        let delegate = AppDelegate()
        // Should not crash when no plist exists
        delegate.migrateFromLaunchAgent()
    }
}
