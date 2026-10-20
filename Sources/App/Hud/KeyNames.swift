import Foundation

/// One physical/virtual key as the HUD understands it: kanata's config name,
/// the macOS virtual keycode it corresponds to, the name kanata's TCP server uses
/// for it in `HoldActivated`/`TapActivated`, and a fallback glyph for keys that
/// have no printable character in the current input source.
struct KeyInfo: Equatable {
    /// Canonical kanata config name (`lsft`, `spc`, `a`, `;`).
    let name: String
    /// macOS virtual keycode (`kVK_*`); -1 when the key has no keycode.
    let keycode: Int
    /// Lower-cased OsCode name kanata's TCP server emits (`leftshift`, `space`).
    let tcpName: String
    /// Glyph to show when the key isn't a character key (modifiers, navigation).
    let glyph: String?
    /// Device-specific `CGEventFlags` bit for modifier keys, 0 otherwise.
    let modifierBit: UInt64

    var isModifier: Bool { modifierBit != 0 }
}

/// Static key table: kanata names ↔ macOS keycodes ↔ kanata TCP names.
///
/// Keycodes are `kVK_*` from Carbon's `Events.h`. TCP names are kanata's
/// `OsCode` `Display` output (the `KEY_` prefix stripped), lower-cased — verified
/// against a live 1.12.0 (`leftmeta`, `semicolon`, `space`).
enum KeyNames {
    // Device-specific modifier bits (IOKit `NX_DEVICE*KEYMASK`).
    static let lctlBit: UInt64 = 0x0000_0001
    static let lsftBit: UInt64 = 0x0000_0002
    static let rsftBit: UInt64 = 0x0000_0004
    static let lmetBit: UInt64 = 0x0000_0008
    static let rmetBit: UInt64 = 0x0000_0010
    static let laltBit: UInt64 = 0x0000_0020
    static let raltBit: UInt64 = 0x0000_0040
    static let rctlBit: UInt64 = 0x0000_2000
    static let fnBit: UInt64 = 0x0080_0000
    static let capsBit: UInt64 = 0x0001_0000

    static let all: [KeyInfo] = {
        var keys: [KeyInfo] = []
        func add(_ name: String, _ keycode: Int, _ tcp: String, glyph: String? = nil, mod: UInt64 = 0) {
            keys.append(KeyInfo(name: name, keycode: keycode, tcpName: tcp, glyph: glyph, modifierBit: mod))
        }
        // Letters
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (l, k) in letters { add(l, k, l) }
        // Digits
        let digits: [(String, Int)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ]
        for (d, k) in digits { add(d, k, d) }
        // Punctuation
        add("=", 24, "equal")
        add("-", 27, "minus")
        add("]", 30, "rightbrace")
        add("[", 33, "leftbrace")
        add("'", 39, "apostrophe")
        add(";", 41, "semicolon")
        add("\\", 42, "backslash")
        add(",", 43, "comma")
        add("/", 44, "slash")
        add(".", 47, "dot")
        add("grv", 50, "grave")
        add("102d", 10, "102nd")
        // Whitespace / editing
        add("ret", 36, "enter", glyph: "↩")
        add("tab", 48, "tab", glyph: "⇥")
        add("spc", 49, "space", glyph: "␣")
        add("bspc", 51, "backspace", glyph: "⌫")
        add("del", 117, "delete", glyph: "⌦")
        add("esc", 53, "esc", glyph: "esc")
        add("caps", 57, "capslock", glyph: "⇪", mod: capsBit)
        // Modifiers
        add("lsft", 56, "leftshift", glyph: "⇧", mod: lsftBit)
        add("rsft", 60, "rightshift", glyph: "⇧", mod: rsftBit)
        add("lctl", 59, "leftctrl", glyph: "⌃", mod: lctlBit)
        add("rctl", 62, "rightctrl", glyph: "⌃", mod: rctlBit)
        add("lalt", 58, "leftalt", glyph: "⌥", mod: laltBit)
        add("ralt", 61, "rightalt", glyph: "⌥", mod: raltBit)
        add("lmet", 55, "leftmeta", glyph: "⌘", mod: lmetBit)
        add("rmet", 54, "rightmeta", glyph: "⌘", mod: rmetBit)
        add("fn", 63, "fn", glyph: "fn", mod: fnBit)
        // Navigation
        add("left", 123, "left", glyph: "←")
        add("right", 124, "right", glyph: "→")
        add("down", 125, "down", glyph: "↓")
        add("up", 126, "up", glyph: "↑")
        add("home", 115, "home", glyph: "↖")
        add("end", 119, "end", glyph: "↘")
        add("pgup", 116, "pageup", glyph: "⇞")
        add("pgdn", 121, "pagedown", glyph: "⇟")
        add("ins", 114, "insert", glyph: "ins")
        // Function row
        let fkeys: [(String, Int)] = [
            ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97), ("f7", 98), ("f8", 100),
            ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111), ("f13", 105), ("f14", 107), ("f15", 113),
            ("f16", 106), ("f17", 64), ("f18", 79), ("f19", 80), ("f20", 90),
        ]
        for (f, k) in fkeys { add(f, k, f, glyph: f.uppercased()) }
        // Media (no keycodes via CGEvent keyDown; label only)
        add("mute", -1, "mute", glyph: "🔇")
        add("volu", -1, "volumeup", glyph: "🔊")
        add("voldwn", -1, "volumedown", glyph: "🔉")
        add("brup", -1, "brightnessup", glyph: "☀︎")
        add("brdown", -1, "brightnessdown", glyph: "☼")
        return keys
    }()

    /// Alternative config spellings kanata accepts for the canonical names above.
    static let aliases: [String: String] = [
        "min": "-", "minus": "-", "eql": "=", "equal": "=", "lbrc": "[", "rbrc": "]", "bksl": "\\",
        "scln": ";", "apo": "'", "comm": ",", "nubs": "102d", "lsgt": "102d", "space": "spc", "enter": "ret",
        "return": "ret", "backspace": "bspc", "escape": "esc", "capslock": "caps", "lmeta": "lmet", "rmeta": "rmet",
        "lshift": "lsft", "rshift": "rsft", "lctrl": "lctl", "rctrl": "rctl", "pgdown": "pgdn", "rght": "right",
        "lft": "left", "dn": "down", "§": "102d", "102nd": "102d",
    ]

    static let byName: [String: KeyInfo] = {
        var map: [String: KeyInfo] = [:]
        for key in all { map[key.name] = key }
        for (alias, canonical) in aliases { map[alias] = map[canonical] }
        return map
    }()

    static let byKeycode: [Int: KeyInfo] = {
        var map: [Int: KeyInfo] = [:]
        for key in all where key.keycode >= 0 { map[key.keycode] = key }
        return map
    }()

    static let byTCPName: [String: KeyInfo] = {
        var map: [String: KeyInfo] = [:]
        for key in all { map[key.tcpName] = key }
        return map
    }()

    /// Canonical kanata name for any accepted spelling, or nil if unknown.
    static func canonical(_ name: String) -> String? { byName[name]?.name }
}
