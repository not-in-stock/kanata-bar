import CoreGraphics
import Foundation

/// What the HUD learns from one keyboard event the OS delivered.
enum InputEvent: Equatable {
    case keyDown(keycode: Int)
    case keyUp(keycode: Int)
    /// A modifier key changed; `keycode` names it, `down` is its new state.
    case modifier(keycode: Int, down: Bool, deviceFlags: UInt64)
}

/// Listen-only session event tap. Never sits in the input delivery path, so it
/// cannot add latency; needs Accessibility (or Input Monitoring) to be created.
///
/// Under kanata the tap sees kanata's *output* (Karabiner virtual keyboard), not
/// physical presses — see the wiki spike S1. Autorepeats are dropped here.
@MainActor
final class InputTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var onEvent: ((InputEvent) -> Void)?
    var onDisabled: (() -> Void)?

    /// Returns false when macOS refuses the tap (no permission).
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: InputTap.callback, userInfo: userInfo) else {
            return false
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    var isRunning: Bool { port != nil }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<InputTap>.fromOpaque(userInfo).takeUnretainedValue()
        // Extract the plain values here; CGEvent itself isn't Sendable.
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags.rawValue
        // The tap's run-loop source lives on the main run loop, so this is the
        // main thread.
        MainActor.assumeIsolated { tap.handle(type: type, keycode: keycode, autorepeat: autorepeat, flags: flags) }
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, keycode: Int, autorepeat: Bool, flags: UInt64) {
        switch type {
        case .keyDown:
            guard !autorepeat else { return }
            onEvent?(.keyDown(keycode: keycode))
        case .keyUp:
            onEvent?(.keyUp(keycode: keycode))
        case .flagsChanged:
            let down: Bool
            if let info = KeyNames.byKeycode[keycode], info.isModifier {
                down = flags & info.modifierBit != 0
            } else {
                down = false
            }
            onEvent?(.modifier(keycode: keycode, down: down, deviceFlags: flags))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onDisabled?()
        default:
            break
        }
    }
}
