import XCTest
@testable import KanataBarLib

/// Deterministic glyph source: US-ish letters/digits for the keycodes the
/// geometry uses, so label tests don't depend on the machine's input source.
struct FakeGlyphs: KeyGlyphSource {
    func character(keycode: Int, shifted: Bool) -> String? {
        guard let info = KeyNames.byKeycode[keycode], info.glyph == nil else { return nil }
        switch info.name {
        case "1": return shifted ? "!" : "1"
        case "2": return shifted ? "@" : "2"
        case "/": return shifted ? "?" : "/"
        case ";": return shifted ? ":" : ";"
        case "grv": return shifted ? "~" : "`"
        case "102d": return shifted ? "±" : "§"
        case "-": return shifted ? "?" : "ß"   // German layout: ß sits on the minus key
        default:
            return info.name.count == 1 ? (shifted ? info.name.uppercased() : info.name) : info.name
        }
    }
}

let sampleConfig = """
(defcfg
    process-unmapped-keys yes
    macos-dev-names-include ("Apple Internal Keyboard / Trackpad"))

(deflocalkeys-macos
    § 192)

(defsrc
    §    1    2    bspc
    tab  q    w    ret
    caps a    s    d    f
    lsft grv  z    rsft
    fn   lctl lalt lmet   spc   rmet ralt)

(defvar
    hrm-tap-time 200
    hrm-hold-time 280
    l-keys (tab q w caps lsft grv z))

(defalias
    ua (fork a (fork (unicode ä) (unicode Ä) (lsft rsft)) (lalt ralt))
    ha (tap-hold-except-keys $hrm-tap-time $hrm-hold-time @ua lctl $l-keys)
    hs (tap-hold-except-keys $hrm-tap-time $hrm-hold-time s lalt $l-keys)
    nav (tap-hold-press 175 200 tab (layer-while-held nav))
    s-? (fork S-/ S-1 (lsft rsft))
    mac (macro a b c))

(deflayer default
    §    1    2    bspc
    tab  q    w    ret
    caps @ha  @hs  d    f
    lsft grv  z    rsft
    fn   lctl lalt @nav   spc   rmet ralt)

;; comment line with ; and (parens)
(deflayer nav
    •    •    •    •
    •    home pgdn @s-?
    •    lctl lalt lmet @mac
    •    _    _    _
    •    •    •    _      _     _    _)
"""

final class KanataConfigParserTests: XCTestCase {
    func parse() throws -> KanataLayout {
        try KanataConfigParser().parse(text: sampleConfig)
    }

    func testTokenizerHandlesCommentsAndStrings() throws {
        let forms = try KanataConfigParser.tokenize("(a \"b c\" ;; comment (x)\n d) #| block |# (e)")
        XCTAssertEqual(forms, [.list([.atom("a"), .atom("b c"), .atom("d")]), .list([.atom("e")])])
    }

    func testSemicolonKeyIsNotAComment() throws {
        let forms = try KanataConfigParser.tokenize("(defsrc ; ')")
        XCTAssertEqual(forms, [.list([.atom("defsrc"), .atom(";"), .atom("'")])])
    }

    func testUnbalancedThrows() {
        XCTAssertThrowsError(try KanataConfigParser.tokenize("(a (b)"))
    }

    func testDefcfgFlags() throws {
        let layout = try parse()
        XCTAssertTrue(layout.processUnmappedKeys)
        XCTAssertFalse(layout.blockUnmappedKeys)
    }

    func testDefsrcAndLayers() throws {
        let layout = try parse()
        XCTAssertEqual(layout.sourceKeys.count, 24)
        XCTAssertEqual(layout.sourceKeys.first, "102d")  // § is the ISO section key
        XCTAssertEqual(layout.layerNames, ["default", "nav"])
    }

    func testAliasAndVarResolution() throws {
        let layout = try parse()
        guard case .tapHold(let tap, let hold) = layout.action(layer: "default", key: "a") else {
            return XCTFail("expected tap-hold on a")
        }
        XCTAssertEqual(hold, .key(name: "lctl", mods: []))
        guard case .fork(let normal, _) = tap else { return XCTFail("expected fork tap") }
        XCTAssertEqual(normal, .key(name: "a", mods: []))
        XCTAssertEqual(layout.action(layer: "default", key: "s"),
                       .tapHold(tap: .key(name: "s", mods: []), hold: .key(name: "lalt", mods: [])))
    }

    func testLayerWhileHeld() throws {
        let layout = try parse()
        XCTAssertEqual(layout.action(layer: "default", key: "lmet"),
                       .tapHold(tap: .key(name: "tab", mods: []), hold: .layerWhileHeld("nav")))
    }

    func testTransparentAndNoop() throws {
        let layout = try parse()
        XCTAssertEqual(layout.action(layer: "nav", key: "102d"), .noop)
        XCTAssertEqual(layout.action(layer: "nav", key: "grv"), .transparent)
        XCTAssertEqual(layout.action(layer: "nav", key: "a"), .key(name: "lctl", mods: []))
    }

    func testModifierPrefixesAndMacro() throws {
        let layout = try parse()
        XCTAssertEqual(layout.action(layer: "nav", key: "ret"),
                       .fork(.key(name: "/", mods: ["S"]), .key(name: "1", mods: ["S"])))
        guard case .macro = layout.action(layer: "nav", key: "f") else { return XCTFail("expected macro") }
    }

    func testDeflayermap() throws {
        let layout = try KanataConfigParser().parse(text: """
        (defsrc a b)
        (deflayermap (base) a b b (layer-switch other) _ XX)
        (deflayer other b a)
        """)
        XCTAssertEqual(layout.action(layer: "base", key: "a"), .key(name: "b", mods: []))
        XCTAssertEqual(layout.action(layer: "base", key: "b"), .layerSwitch("other"))
        XCTAssertEqual(layout.layerNames, ["base", "other"])
    }

    func testIncludeIsExpandedRelativeToBaseDir() throws {
        var parser = KanataConfigParser()
        parser.fileReader = { path in
            XCTAssertEqual(path, "/cfg/extra.kbd")
            return "(defalias x (layer-switch two))"
        }
        let layout = try parser.parse(text: """
        (include "extra.kbd")
        (defsrc a)
        (deflayer one @x)
        (deflayer two a)
        """, baseDir: "/cfg")
        XCTAssertEqual(layout.action(layer: "one", key: "a"), .layerSwitch("two"))
    }

    func testUnknownActionBecomesOther() throws {
        let layout = try KanataConfigParser().parse(text: "(defsrc a)(deflayer l (switch ((lsft)) b break () a break))")
        guard case .other(let text) = layout.action(layer: "l", key: "a") else { return XCTFail("expected other") }
        XCTAssertTrue(text.hasPrefix("(switch"))
    }
}

final class KeyboardGeometryTests: XCTestCase {
    func testEveryFullRowIs14_5Units() {
        for kind in [KeyboardLayoutKind.ansi, .iso] {
            let g = KeyboardGeometry.make(kind)
            let rows = Dictionary(grouping: g.caps.filter { $0.height >= 1 }, by: { $0.y })
            for (y, caps) in rows where y >= KeyboardGeometry.fnRowHeight && y < g.heightUnits - 1 {
                // ISO return's lower part belongs to the home row but is an `extra`.
                let extras = g.caps.compactMap(\.extra).filter { $0.y == y }.map(\.width).reduce(0, +)
                let width = caps.map(\.width).reduce(0, +) + extras
                XCTAssertEqual(width, 14.5, accuracy: 0.001, "\(kind) row at y=\(y)")
            }
        }
    }

    func testIsoHasSectionKeyAndGraveNextToShift() {
        let iso = KeyboardGeometry.make(.iso)
        XCTAssertEqual(iso.cap(named: "102d")?.y, KeyboardGeometry.fnRowHeight)
        XCTAssertEqual(iso.cap(named: "grv")?.x, 1.25)
        XCTAssertNotNil(iso.cap(named: "ret")?.extra)
        let ansi = KeyboardGeometry.make(.ansi)
        XCTAssertNil(ansi.cap(named: "102d"))
        XCTAssertEqual(ansi.cap(named: "grv")?.x, 0)
    }

    func testNoDuplicateNames() {
        for kind in [KeyboardLayoutKind.ansi, .iso] {
            let names = KeyboardGeometry.make(kind).caps.compactMap(\.name)
            XCTAssertEqual(names.count, Set(names).count)
            for name in names { XCTAssertNotNil(KeyNames.byName[name], "unknown key \(name)") }
        }
    }
}

final class LabelResolverTests: XCTestCase {
    let resolver = LabelResolver(glyphs: FakeGlyphs())
    lazy var layout = try! KanataConfigParser().parse(text: sampleConfig)

    func testKanataStoppedGivesSystemLabels() {
        XCTAssertEqual(resolver.label(for: "a", layout: nil, layer: nil), KeyLabel(main: "A", secondary: nil, kind: .plain, detail: nil))
        XCTAssertEqual(resolver.label(for: "lsft", layout: layout, layer: nil).main, "⇧")
    }

    func testSharpSIsNotUppercasedToSS() {
        XCTAssertEqual(resolver.label(for: "-", layout: nil, layer: nil).main, "ß")
        XCTAssertEqual(resolver.label(for: "a", layout: nil, layer: nil).main, "A")
        XCTAssertEqual(resolver.label(for: "1", layout: nil, layer: nil).main, "1")
    }

    func testTapHoldShowsBothLegends() {
        let l = resolver.label(for: "a", layout: layout, layer: "default")
        XCTAssertEqual(l.main, "A")
        XCTAssertEqual(l.secondary, "⌃")
        XCTAssertEqual(l.kind, .remapped)
        let lmet = resolver.label(for: "lmet", layout: layout, layer: "default")
        XCTAssertEqual(lmet.main, "⇥")
        XCTAssertEqual(lmet.secondary, "nav")
    }

    func testIdentityMappingIsPlain() {
        XCTAssertEqual(resolver.label(for: "1", layout: layout, layer: "default").kind, .plain)
        XCTAssertEqual(resolver.label(for: "d", layout: layout, layer: "default").kind, .plain)
    }

    func testUnmappedKeyFollowsBlockFlag() {
        var blocked = layout
        XCTAssertEqual(resolver.label(for: "x", layout: layout, layer: "default").kind, .plain)
        blocked.blockUnmappedKeys = true
        XCTAssertEqual(resolver.label(for: "x", layout: blocked, layer: "default"), .empty)
    }

    func testNoopIsBlankAndTransparentFallsToBase() {
        XCTAssertEqual(resolver.label(for: "102d", layout: layout, layer: "nav"), .empty)
        let grv = resolver.label(for: "grv", layout: layout, layer: "nav")
        XCTAssertEqual(grv.main, "`")
        XCTAssertEqual(grv.kind, .plain)
        // `_` on a key the base layer remaps keeps the base remap.
        let lmet = resolver.label(for: "lmet", layout: layout, layer: "nav")
        XCTAssertEqual(lmet.secondary, "nav")
    }

    func testForkShowsShiftedVariant() {
        let l = resolver.label(for: "ret", layout: layout, layer: "nav")
        XCTAssertEqual(l.main, "?")
        XCTAssertEqual(l.secondary, "!")
    }

    func testMacroAndUnicode() {
        let f = resolver.label(for: "f", layout: layout, layer: "nav")
        XCTAssertEqual(f.main, LabelResolver.placeholder)
        XCTAssertEqual(f.detail, "(macro a b c)")
        XCTAssertEqual(resolver.label(forAction: .unicode("ä"), key: "a").main, "ä")
        XCTAssertEqual(resolver.label(forAction: .key(name: "c", mods: ["M"]), key: "c").main, "⌘C")
    }
}

@MainActor
final class HudStateTests: XCTestCase {
    var state: HudState!
    var clock = Date(timeIntervalSince1970: 1000)

    override func setUp() {
        state = HudState(geometry: .make(.iso), resolver: LabelResolver(glyphs: FakeGlyphs()))
        state.now = { self.clock }
        state.setLayout(try! KanataConfigParser().parse(text: sampleConfig))
        state.setLayer("default")
    }

    func testPressedTracksOutputKeycodes() {
        state.input(.keyDown(keycode: 0))
        XCTAssertTrue(state.isPressed("a"))
        state.input(.keyUp(keycode: 0))
        XCTAssertFalse(state.isPressed("a"))
    }

    func testModifierHoldEndsOnReleaseAfterPress() {
        state.holdActivated(tcpKey: "a")
        state.input(.modifier(keycode: 59, down: true, deviceFlags: KeyNames.lctlBit))
        XCTAssertTrue(state.isHoldActive("a"))
        // The held cap lights, the native modifier cap doesn't.
        XCTAssertTrue(state.isPressed("a"))
        XCTAssertFalse(state.isPressed("lctl"))
        state.input(.modifier(keycode: 59, down: false, deviceFlags: 0))
        XCTAssertFalse(state.isHoldActive("a"))
        XCTAssertFalse(state.isPressed("a"))
    }

    func testModifierHoldEndsWhenReleaseWasInsideGrace() {
        // Instant press+release right after HoldActivated: no later evidence.
        state.holdActivated(tcpKey: "a")
        state.input(.modifier(keycode: 59, down: true, deviceFlags: KeyNames.lctlBit))
        state.input(.modifier(keycode: 59, down: false, deviceFlags: 0))
        XCTAssertFalse(state.isHoldActive("a"))
    }

    func testReleaseWithoutPressIsIgnoredInsideGrace() {
        state.input(.modifier(keycode: 59, down: true, deviceFlags: KeyNames.lctlBit))
        state.holdActivated(tcpKey: "a")
        state.input(.modifier(keycode: 61, down: false, deviceFlags: 0))  // unrelated, flag already clear
        XCTAssertTrue(state.isHoldActive("a"))
        clock += Timing.hudHoldGrace + 0.01
        state.tick()
        XCTAssertFalse(state.isHoldActive("a"))
    }

    func testPhysicalModifierLightsItself() {
        state.input(.modifier(keycode: 56, down: true, deviceFlags: KeyNames.lsftBit))
        XCTAssertTrue(state.isPressed("lsft"))
        XCTAssertFalse(state.isPressed("f"))  // f's hold produces lsft, but no hold is active
    }

    func testRemappedOutputLightsThePhysicalCap() {
        state.setLayer("nav")
        state.input(.keyDown(keycode: 59))  // lctl, produced by `a` on nav
        XCTAssertTrue(state.isPressed("a"))
        XCTAssertFalse(state.isPressed("lctl"))
        state.input(.keyDown(keycode: 115))  // home, produced by `q` on nav
        XCTAssertTrue(state.isPressed("q"))
    }

    func testLayerHoldEndsWhenLayerLeaves() {
        state.holdActivated(tcpKey: "leftmeta")
        XCTAssertTrue(state.isHoldActive("lmet"))
        state.setLayer("nav")
        XCTAssertTrue(state.isHoldActive("lmet"))
        XCTAssertEqual(state.labels["a"]?.main, "⌃")
        state.setLayer("default")
        XCTAssertFalse(state.isHoldActive("lmet"))
    }

    func testTapFlashExpires() {
        state.tapActivated(tcpKey: "s")
        XCTAssertTrue(state.isTapFlashing("s"))
        clock += Timing.hudTapFlash + 0.01
        XCTAssertTrue(state.tick())
        XCTAssertFalse(state.isTapFlashing("s"))
    }

    func testUnknownHoldTimesOut() {
        state.setLayer("nav")
        state.holdActivated(tcpKey: "f")  // macro hold → no end signal
        XCTAssertTrue(state.isHoldActive("f"))
        clock += Timing.hudHoldFallback + 0.1
        state.tick()
        XCTAssertFalse(state.isHoldActive("f"))
    }

    func testKanataStoppedClearsTransientsAndLabels() {
        state.holdActivated(tcpKey: "a")
        state.kanataStopped()
        XCTAssertFalse(state.isHoldActive("a"))
        XCTAssertEqual(state.labels["a"]?.kind, .plain)
        XCTAssertNil(state.labels["a"]?.secondary)
    }
}

final class KanataEventHudTests: XCTestCase {
    func testHoldAndTapActivated() {
        XCTAssertEqual(KanataEvent.parse(#"{"HoldActivated":{"key":"leftmeta"}}"#), .holdActivated("leftmeta"))
        XCTAssertEqual(KanataEvent.parse(#"{"TapActivated":{"key":"A"}}"#), .tapActivated("a"))
    }
}
