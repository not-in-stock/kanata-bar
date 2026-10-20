import AppKit

/// Floating, non-activating frosted-glass panel that hosts the keyboard view.
/// Title is fixed ("Kanata HUD") so window-manager rules can target it.
@MainActor
final class HudPanel: NSPanel {
    static let windowTitle = "Kanata HUD"
    static let autosaveName = "KanataHUDPanel"

    init(contentView view: NSView) {
        let size = view.intrinsicContentSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        title = Self.windowTitle
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 12)
        view.frame = effect.bounds
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        contentView = effect

        setFrameAutosaveName(Self.autosaveName)
        if !setFrameUsingName(Self.autosaveName) { center() }
        setContentSize(size)
    }

    /// Resizable rounded-rect mask; `capInsets` keep the corners intact when the
    /// view is resized. Masking the effect view (not its layer) also rounds the
    /// window's shadow.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = radius * 2 + 1
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // A borderless panel can't become key by default; we don't want key status
    // at all (typing must keep going to the frontmost app).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
