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
