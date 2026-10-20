import Foundation

/// Physical layout family of a Magic-Keyboard-style laptop keyboard.
enum KeyboardLayoutKind: String, Equatable {
    case ansi
    case iso
}

/// A rectangle in key units, origin top-left.
struct KeyRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// One keycap in a geometry: where it sits (in key units, origin top-left) and
/// which kanata key it is. `name` is nil for caps kanata can't address (power).
struct KeyCap: Equatable {
    let name: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// ISO return is L-shaped: the lower part is a second rect that is drawn as
    /// one cap with the main rect.
    let extra: KeyRect?

    init(_ name: String?, x: Double, y: Double, width: Double, height: Double = 1, extra: KeyRect? = nil) {
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.extra = extra
    }
}

/// Magic Keyboard (laptop, no numpad) geometry in ANSI or ISO form.
///
/// Rows are 1 unit tall except the half-height function row; every full row is
/// 14.5 units wide, which is what a MacBook / Magic Keyboard body is.
struct KeyboardGeometry: Equatable {
    let kind: KeyboardLayoutKind
    let caps: [KeyCap]
    let widthUnits: Double
    let heightUnits: Double

    static let fnRowHeight = 0.6
    static let rowWidth = 14.5

    static func make(_ kind: KeyboardLayoutKind) -> KeyboardGeometry {
        var caps: [KeyCap] = []
        func row(_ y: Double, _ items: [(String?, Double)], height: Double = 1) {
            var x = 0.0
            for (name, width) in items {
                caps.append(KeyCap(name, x: x, y: y, width: width, height: height))
                x += width
            }
        }

        // Function row (half height): esc, F1–F12, power/Touch ID.
        var fnRow: [(String?, Double)] = [("esc", 1.5)]
        for i in 1...12 { fnRow.append(("f\(i)", 1.0)) }
        fnRow.append((nil, 1.0))
        row(0, fnRow, height: fnRowHeight)

        let y1 = fnRowHeight
        // Number row. ISO has § (kVK 10) top-left; ANSI has grave there.
        let topLeft = kind == .iso ? "102d" : "grv"
        row(y1, [(topLeft, 1), ("1", 1), ("2", 1), ("3", 1), ("4", 1), ("5", 1), ("6", 1), ("7", 1), ("8", 1),
                 ("9", 1), ("0", 1), ("-", 1), ("=", 1), ("bspc", 1.5),
        ])

        // Tab row.
        var tabRow: [(String?, Double)] = [("tab", 1.5), ("q", 1), ("w", 1), ("e", 1), ("r", 1), ("t", 1), ("y", 1),
                                           ("u", 1), ("i", 1), ("o", 1), ("p", 1), ("[", 1), ("]", 1),
        ]
        if kind == .ansi { tabRow.append(("\\", 1)) }
        row(y1 + 1, tabRow)

        // Home row.
        var homeRow: [(String?, Double)] = [("caps", 1.75), ("a", 1), ("s", 1), ("d", 1), ("f", 1), ("g", 1), ("h", 1),
                                            ("j", 1), ("k", 1), ("l", 1), (";", 1), ("'", 1),
        ]
        if kind == .ansi {
            homeRow.append(("ret", 1.75))
            row(y1 + 2, homeRow)
        } else {
            homeRow.append(("\\", 1))
            row(y1 + 2, homeRow)
            // ISO return: 1u wide on the tab row, 0.75u on the home row, joined.
            caps.append(KeyCap("ret", x: 13.5, y: y1 + 1, width: 1, height: 1,
                               extra: KeyRect(x: 13.75, y: y1 + 2, width: 0.75, height: 1)))
        }

        // Shift row. ISO has the grave key (kVK 50) next to left shift.
        var shiftRow: [(String?, Double)] = kind == .iso ? [("lsft", 1.25), ("grv", 1)] : [("lsft", 2.25)]
        shiftRow += [("z", 1), ("x", 1), ("c", 1), ("v", 1), ("b", 1), ("n", 1), ("m", 1), (",", 1), (".", 1), ("/", 1),
                     ("rsft", 2.25),
        ]
        row(y1 + 3, shiftRow)

        // Bottom row with the inverted-T arrows (up/down are half height).
        let y5 = y1 + 4
        row(y5, [("fn", 1), ("lctl", 1), ("lalt", 1), ("lmet", 1.25), ("spc", 5), ("rmet", 1.25), ("ralt", 1)])
        caps.append(KeyCap("left", x: 11.5, y: y5 + 0.5, width: 1, height: 0.5))
        caps.append(KeyCap("up", x: 12.5, y: y5, width: 1, height: 0.5))
        caps.append(KeyCap("down", x: 12.5, y: y5 + 0.5, width: 1, height: 0.5))
        caps.append(KeyCap("right", x: 13.5, y: y5 + 0.5, width: 1, height: 0.5))

        return KeyboardGeometry(kind: kind, caps: caps, widthUnits: rowWidth, heightUnits: y5 + 1)
    }

    func cap(named name: String) -> KeyCap? { caps.first { $0.name == name } }
}
