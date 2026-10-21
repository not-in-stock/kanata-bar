import AppKit

/// Draws the keyboard from `HudState`. Direct drawing, no per-key layers: a full
/// redraw of ~80 caps is well under a millisecond, and only the dirty caps are
/// redrawn on state changes.
@MainActor
final class HudKeyboardView: NSView {
    let state: HudState
    var unit: CGFloat = 44
    let padding: CGFloat = 10
    private let gap: CGFloat = 5
    private var lastDrawn: [String: Snapshot] = [:]

    private struct Snapshot: Equatable {
        let label: KeyLabel
        let pressed: Bool
        let hold: Bool
        let flash: Bool
        var locked = false
    }

    init(state: HudState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: state.geometry.widthUnits * unit + padding * 2,
               height: state.geometry.heightUnits * unit + padding * 2)
    }

    // MARK: - Invalidation

    /// Redraw only caps whose appearance changed since the last draw.
    func refresh() {
        var any = false
        for cap in state.geometry.caps {
            guard let name = cap.name else { continue }
            if snapshot(name) != lastDrawn[name] {
                setNeedsDisplay(rect(for: cap).insetBy(dx: -1, dy: -1))
                if let extra = cap.extra { setNeedsDisplay(extraRect(extra).insetBy(dx: -1, dy: -1)) }
                any = true
            }
        }
        if !any && lastDrawn.isEmpty { needsDisplay = true }
        // Draw now rather than on the next run-loop pass: one key's worth of work.
        displayIfNeeded()
    }

    private func extraRect(_ r: KeyRect) -> NSRect {
        NSRect(x: padding + r.x * unit, y: padding + r.y * unit, width: r.width * unit, height: r.height * unit)
    }

    private func snapshot(_ name: String) -> Snapshot {
        Snapshot(label: state.labels[name] ?? .empty, pressed: state.isPressed(name),
                 hold: state.isHoldActive(name), flash: state.isTapFlashing(name),
                 locked: name == "caps" && state.capsLockOn)
    }

    private func rect(for cap: KeyCap) -> NSRect {
        NSRect(x: padding + cap.x * unit, y: padding + cap.y * unit,
               width: cap.width * unit, height: cap.height * unit)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        for cap in state.geometry.caps {
            let r = rect(for: cap)
            var hit = r.intersects(dirtyRect)
            if let extra = cap.extra { hit = hit || extraRect(extra).intersects(dirtyRect) }
            guard hit else { continue }
            drawCap(cap, in: r)
            if let name = cap.name { lastDrawn[name] = snapshot(name) }
        }
    }

    private func drawCap(_ cap: KeyCap, in rect: NSRect) {
        let snap = cap.name.map(snapshot) ?? Snapshot(label: .empty, pressed: false, hold: false, flash: false)
        let path = capPath(cap, rect)

        // Fill
        let fill: NSColor
        if snap.pressed || snap.flash {
            fill = NSColor.controlAccentColor.withAlphaComponent(snap.flash && !snap.pressed ? 0.45 : 0.7)
        } else if snap.hold {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.25)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(snap.label.kind == .blocked ? 0.04 : 0.09)
        }
        fill.setFill()
        path.fill()

        // Border: accent while pressed / hold, hairline otherwise.
        let stroke = (snap.pressed || snap.hold || snap.flash)
            ? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(0.12)
        stroke.setStroke()
        path.lineWidth = snap.pressed || snap.hold ? 1.5 : 0.75
        path.stroke()

        guard cap.name != nil else { return }
        drawLabels(snap, cap: cap, rect: rect)
        if snap.locked {
            // Caps Lock "LED": a small dot in the top-left corner, like the hardware.
            let d = max(3, unit * 0.09)
            let dot = NSRect(x: rect.minX + gap / 2 + d, y: rect.minY + gap / 2 + d, width: d, height: d)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    private func capPath(_ cap: KeyCap, _ rect: NSRect) -> NSBezierPath {
        let inset = rect.insetBy(dx: gap / 2, dy: gap / 2)
        let radius = min(6, unit * 0.14)
        guard let extra = cap.extra else {
            return NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        }
        // ISO return: union of the two rects, drawn as one rounded shape.
        let lower = extraRect(extra).insetBy(dx: gap / 2, dy: gap / 2)
        let path = NSBezierPath()
        let r = radius
        // Clockwise from top-left of the upper rect.
        path.move(to: NSPoint(x: inset.minX + r, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX - r, y: inset.minY))
        path.appendArc(withCenter: NSPoint(x: inset.maxX - r, y: inset.minY + r), radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: inset.maxX, y: lower.maxY - r))
        path.appendArc(withCenter: NSPoint(x: inset.maxX - r, y: lower.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: lower.minX + r, y: lower.maxY))
        path.appendArc(withCenter: NSPoint(x: lower.minX + r, y: lower.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: lower.minX, y: inset.maxY + r))
        path.appendArc(withCenter: NSPoint(x: lower.minX - r, y: inset.maxY + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: NSPoint(x: inset.minX + r, y: inset.maxY))
        path.appendArc(withCenter: NSPoint(x: inset.minX + r, y: inset.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: inset.minX, y: inset.minY + r))
        path.appendArc(withCenter: NSPoint(x: inset.minX + r, y: inset.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    private func drawLabels(_ snap: Snapshot, cap: KeyCap, rect: NSRect) {
        let label = snap.label
        let color: NSColor
        switch label.kind {
        case .remapped: color = .labelColor
        case .plain: color = NSColor.labelColor.withAlphaComponent(0.45)
        case .blocked: color = .clear
        }
        // Inner padding keeps legends off the cap edge; both legends give up 1pt for it.
        let inner: CGFloat = 1
        let mainSize = (cap.height < 0.8 ? unit * 0.22 : (label.main.count > 2 ? unit * 0.24 : unit * 0.34)) - 1
        let mainFont = NSFont.systemFont(ofSize: mainSize, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        let hasSecondary = label.secondary != nil && !(label.secondary?.isEmpty ?? true) && cap.height >= 0.8
        let mainAttrs: [NSAttributedString.Key: Any] = [.font: mainFont, .foregroundColor: color, .paragraphStyle: para]
        let mainText = NSAttributedString(string: label.main, attributes: mainAttrs)
        let mainHeight = mainText.size().height
        // The main legend always sits in the same centered slot, whether or not
        // the cap has a secondary one — so rows stay level across keys and layers.
        let mainY = rect.midY - mainHeight / 2
        mainText.draw(in: NSRect(x: rect.minX + 2 + inner, y: mainY, width: rect.width - 4 - inner * 2, height: mainHeight))

        if hasSecondary, let secondary = label.secondary {
            let secColor = snap.hold ? NSColor.controlAccentColor : color
            let secFont = NSFont.systemFont(ofSize: unit * 0.2 - 1, weight: snap.hold ? .semibold : .regular)
            let secAttrs: [NSAttributedString.Key: Any] = [.font: secFont, .foregroundColor: secColor, .paragraphStyle: para]
            let secText = NSAttributedString(string: secondary, attributes: secAttrs)
            let h = secText.size().height
            // Centered in the strip between the main slot and the cap's bottom edge.
            let stripTop = mainY + mainHeight
            let stripBottom = rect.maxY - gap / 2 - inner
            let y = stripTop + max(0, (stripBottom - stripTop - h) / 2)
            secText.draw(in: NSRect(x: rect.minX + 2 + inner, y: y, width: rect.width - 4 - inner * 2, height: h))
        }
    }
}
