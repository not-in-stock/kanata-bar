import XCTest
@testable import KanataBarLib

final class KanataEventTests: XCTestCase {

    // MARK: - LayerChange

    func testLayerChange() {
        let event = KanataEvent.parse(#"{"LayerChange":{"new":"nav"}}"#)
        XCTAssertEqual(event, .layerChange("nav"))
    }

    func testLayerChangeWithOldField() {
        let event = KanataEvent.parse(#"{"LayerChange":{"new":"sym","old":"default"}}"#)
        XCTAssertEqual(event, .layerChange("sym"))
    }

    func testLayerChangeEmoji() {
        let event = KanataEvent.parse(#"{"LayerChange":{"new":"🔥nav"}}"#)
        XCTAssertEqual(event, .layerChange("🔥nav"))
    }

    func testLayerChangeEmptyName() {
        let event = KanataEvent.parse(#"{"LayerChange":{"new":""}}"#)
        XCTAssertEqual(event, .layerChange(""))
    }

    func testLayerChangeMissingNewField() {
        let event = KanataEvent.parse(#"{"LayerChange":{"old":"default"}}"#)
        XCTAssertNil(event)
    }

    // MARK: - ConfigFileReload

    func testConfigReload() {
        let event = KanataEvent.parse(#"{"ConfigFileReload":{}}"#)
        XCTAssertEqual(event, .configReload)
    }

    func testConfigReloadWithPayload() {
        let event = KanataEvent.parse(#"{"ConfigFileReload":{"new":"/path/to/config"}}"#)
        XCTAssertEqual(event, .configReload)
    }

    // MARK: - ReloadResult / Error

    func testReloadResultOk() {
        XCTAssertEqual(KanataEvent.parse(#"{"ReloadResult":{"ok":true}}"#), .reloadResult(ok: true, timedOut: false))
    }

    func testReloadResultFailed() {
        XCTAssertEqual(KanataEvent.parse(#"{"ReloadResult":{"ok":false}}"#), .reloadResult(ok: false, timedOut: false))
    }

    func testReloadResultTimedOut() {
        XCTAssertEqual(KanataEvent.parse(#"{"ReloadResult":{"ok":true,"timeout_ms":5000}}"#),
                       .reloadResult(ok: true, timedOut: true))
    }

    func testReloadResultMissingOk() {
        XCTAssertNil(KanataEvent.parse(#"{"ReloadResult":{}}"#))
    }

    func testErrorMessage() {
        XCTAssertEqual(KanataEvent.parse(#"{"Error":{"msg":"unknown layer"}}"#), .error("unknown layer"))
    }

    func testBareOkResponseIsIgnored() {
        XCTAssertNil(KanataEvent.parse(#""Ok""#))
    }

    // MARK: - Unknown / Invalid

    func testUnknownEvent() {
        let event = KanataEvent.parse(#"{"FakeKeyInput":{"key":"a"}}"#)
        XCTAssertNil(event)
    }

    func testInvalidJSON() {
        XCTAssertNil(KanataEvent.parse("not json"))
    }

    func testEmptyString() {
        XCTAssertNil(KanataEvent.parse(""))
    }

    func testEmptyObject() {
        XCTAssertNil(KanataEvent.parse("{}"))
    }

    func testArrayInsteadOfObject() {
        XCTAssertNil(KanataEvent.parse("[1,2,3]"))
    }
}
