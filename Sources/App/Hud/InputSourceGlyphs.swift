import Carbon
import Foundation

/// Characters from the user's current keyboard input source, via
/// `UCKeyTranslate`. Re-created on every input-source change (cheap).
@MainActor
final class InputSourceGlyphs: KeyGlyphSource {
    private var layoutData: Data?
    /// Keyboard type handed to `UCKeyTranslate`. It decides the ISO swap of
    /// `§`/`` ` `` (kVK 10 vs 50), so it must follow the *physical* geometry —
    /// `LMGetKbdType()` would report Karabiner's virtual keyboard (ANSI) under kanata.
    var keyboardType: UInt32 = InputSourceGlyphs.ansiType

    /// IOHIDFamily's handler ids for USB keyboards by HID country code.
    static let ansiType: UInt32 = 40
    static let isoType: UInt32 = 41

    init(kind: KeyboardLayoutKind) {
        keyboardType = kind == .iso ? Self.isoType : Self.ansiType
        reload()
    }

    func reload() {
        layoutData = nil
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let cfData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        layoutData = cfData as Data
    }

    /// Identifier of the current input source, for logging and change detection.
    static func currentSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    nonisolated func character(keycode: Int, shifted: Bool) -> String? {
        MainActor.assumeIsolated {
            guard let layoutData else { return nil }
            return layoutData.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let modifiers: UInt32 = shifted ? UInt32((shiftKey >> 8) & 0xFF) : 0
                let status = UCKeyTranslate(layout, UInt16(keycode), UInt16(kUCKeyActionDisplay), modifiers,
                                            keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                let text = String(utf16CodeUnits: chars, count: length)
                // A dead key may come back as a bare combining mark; give it a base.
                if text.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) {
                    return "\u{25CC}" + text
                }
                return text
            }
        }
    }
}
