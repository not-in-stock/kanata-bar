import Carbon
import Foundation

/// Characters from the user's current keyboard input source, via
/// `UCKeyTranslate`. Re-created on every input-source change (cheap).
@MainActor
final class InputSourceGlyphs: KeyGlyphSource {
    private var layoutData: Data?
    private let keyboardType: UInt32

    init() {
        keyboardType = UInt32(LMGetKbdType())
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
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }
}
