import Foundation

/// Supplies the character a keycode produces in the current input source.
/// Abstracted so the resolver is testable without Text Input Services.
protocol KeyGlyphSource {
    /// Printable character for `keycode`, with or without shift, or nil.
    func character(keycode: Int, shifted: Bool) -> String?
}

/// Everything the HUD draws on one keycap.
struct KeyLabel: Equatable {
    enum Kind: Equatable {
        /// kanata doesn't touch this key (not in defsrc, or identity mapping).
        case plain
        /// kanata remaps this key in the current layer.
        case remapped
        /// kanata swallows this key (`XX`, or `block-unmapped-keys`).
        case blocked
    }

    var main: String
    /// Secondary legend at the bottom of the cap: the hold action of a tap-hold,
    /// or the shifted branch of a fork.
    var secondary: String?
    var kind: Kind
    /// Raw action text for tooltips when the label is a placeholder.
    var detail: String?

    static let empty = KeyLabel(main: "", secondary: nil, kind: .blocked, detail: nil)
}

/// Builds keycap labels from the parsed layout, the active layer and the
/// current input source.
struct LabelResolver {
    let glyphs: KeyGlyphSource
    static let placeholder = "⋯"

    /// Label for `key` with kanata active on `layer`. `layer == nil` means kanata
    /// isn't running: plain system labels for every key.
    func label(for key: String, layout: KanataLayout?, layer: String?) -> KeyLabel {
        guard let layout, let layer, layout.layers[layer] != nil else {
            return KeyLabel(main: systemGlyph(key), secondary: nil, kind: .plain, detail: nil)
        }
        guard layout.sourceKeys.contains(key) else {
            if layout.blockUnmappedKeys { return .empty }
            return KeyLabel(main: systemGlyph(key), secondary: nil, kind: .plain, detail: nil)
        }
        let action = resolveTransparent(key: key, layout: layout, layer: layer)
        return label(forAction: action, key: key)
    }

    /// Follows `_` down to the base layer (or the first layer with
    /// `delegate-to-first-layer`), then to the key itself.
    private func resolveTransparent(key: String, layout: KanataLayout, layer: String) -> KanataAction {
        var action = layout.action(layer: layer, key: key) ?? .transparent
        if action == .transparent, let base = layout.firstLayer, base != layer {
            action = layout.action(layer: base, key: key) ?? .transparent
        }
        if action == .transparent { action = .key(name: key, mods: []) }
        return action
    }

    func label(forAction action: KanataAction, key: String) -> KeyLabel {
        switch action {
        case .key(let name, let mods):
            let text = modifierPrefix(mods) + keyGlyph(name, shifted: mods.contains("S") || mods.contains("RS"))
            let identity = name == key && mods.isEmpty
            return KeyLabel(main: text, secondary: nil, kind: identity ? .plain : .remapped, detail: nil)
        case .transparent:
            return KeyLabel(main: systemGlyph(key), secondary: nil, kind: .plain, detail: nil)
        case .noop:
            return .empty
        case .layerWhileHeld(let name), .layerSwitch(let name):
            return KeyLabel(main: name, secondary: nil, kind: .remapped, detail: nil)
        case .unicode(let s):
            return KeyLabel(main: s, secondary: nil, kind: .remapped, detail: nil)
        case .macro(let text), .other(let text):
            return KeyLabel(main: Self.placeholder, secondary: nil, kind: .remapped, detail: text)
        default:
            return compoundLabel(forAction: action, key: key)
        }
    }

    /// Labels for actions built from other actions.
    private func compoundLabel(forAction action: KanataAction, key: String) -> KeyLabel {
        switch action {
        case .tapHold(let tap, let hold):
            let tapLabel = label(forAction: tap, key: key)
            let holdLabel = label(forAction: hold, key: key)
            return KeyLabel(main: tapLabel.main, secondary: holdLabel.main, kind: .remapped, detail: nil)
        case .oneShot(let inner):
            var l = label(forAction: inner, key: key)
            l.kind = .remapped
            return l
        case .fork(let normal, let shifted):
            let n = label(forAction: normal, key: key)
            let s = label(forAction: shifted, key: key)
            return KeyLabel(main: n.main, secondary: s.main == n.main ? n.secondary : s.main, kind: .remapped, detail: nil)
        case .multi(let actions):
            let first = actions.first { if case .key = $0 { return true } else { return false } } ?? actions.first
            let l = first.map { label(forAction: $0, key: key) }
            return KeyLabel(main: l?.main ?? Self.placeholder, secondary: nil, kind: .remapped, detail: "multi")
        case .tapDance(let actions):
            let l = actions.first.map { label(forAction: $0, key: key) }
            return KeyLabel(main: (l?.main ?? "") + "⁺", secondary: nil, kind: .remapped, detail: "tap-dance")
        default:
            return KeyLabel(main: Self.placeholder, secondary: nil, kind: .remapped, detail: nil)
        }
    }

    // MARK: - Glyphs

    /// Label for a key as the OS would show it: the input source's character,
    /// else the key's fixed glyph, else its name.
    func systemGlyph(_ key: String) -> String {
        keyGlyph(key, shifted: false)
    }

    func keyGlyph(_ key: String, shifted: Bool) -> String {
        guard let info = KeyNames.byName[key] else { return key }
        if let glyph = info.glyph { return glyph }
        if info.keycode >= 0, let ch = glyphs.character(keycode: info.keycode, shifted: shifted),
           !ch.isEmpty, ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return shifted ? ch : ch.uppercased()
        }
        return info.name
    }

    private func modifierPrefix(_ mods: Set<String>) -> String {
        var out = ""
        if mods.contains("C") || mods.contains("RC") { out += "⌃" }
        if mods.contains("A") || mods.contains("RA") || mods.contains("AG") { out += "⌥" }
        if mods.contains("M") || mods.contains("RM") { out += "⌘" }
        return out
    }
}
