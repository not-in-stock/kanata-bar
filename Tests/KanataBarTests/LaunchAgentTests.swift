import XCTest
@testable import KanataBarLib

final class LaunchAgentTests: XCTestCase {

    func testBuildPlistAbsolutePath() {
        let plist = AppDelegate.buildPlist(
            args: ["/Applications/Kanata Bar.app/Contents/MacOS/kanata-bar"],
            cwd: "/Users/test"
        )
        XCTAssertTrue(plist.contains("<string>/Applications/Kanata Bar.app/Contents/MacOS/kanata-bar</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<true/>"))
        XCTAssertTrue(plist.contains("<key>Label</key>"))
        XCTAssertTrue(plist.contains("<string>com.kanata-bar</string>"))
    }

    func testBuildPlistRelativePath() {
        let plist = AppDelegate.buildPlist(
            args: ["kanata-bar"],
            cwd: "/Users/test/build"
        )
        XCTAssertTrue(plist.contains("<string>/Users/test/build/kanata-bar</string>"))
    }

    func testBuildPlistWithExtraArgs() {
        let plist = AppDelegate.buildPlist(
            args: ["/usr/local/bin/kanata-bar", "--config-file", "/path/to/config.toml", "--port", "9999"],
            cwd: "/tmp"
        )
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/kanata-bar</string>"))
        XCTAssertTrue(plist.contains("<string>--config-file</string>"))
        XCTAssertTrue(plist.contains("<string>/path/to/config.toml</string>"))
        XCTAssertTrue(plist.contains("<string>--port</string>"))
        XCTAssertTrue(plist.contains("<string>9999</string>"))
    }

    func testBuildPlistIsValidXML() throws {
        let plist = AppDelegate.buildPlist(
            args: ["/usr/local/bin/kanata-bar"],
            cwd: "/tmp"
        )
        let data = plist.data(using: .utf8)!
        let xml = try XMLDocument(data: data)
        XCTAssertNotNil(xml.rootElement())
    }
}
