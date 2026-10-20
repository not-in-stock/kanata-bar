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
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        view.frame = effect.bounds
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        contentView = effect

        setFrameAutosaveName(Self.autosaveName)
        if !setFrameUsingName(Self.autosaveName) { center() }
        setContentSize(size)
    }

    // A borderless panel can't become key by default; we don't want key status
    // at all (typing must keep going to the frontmost app).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
