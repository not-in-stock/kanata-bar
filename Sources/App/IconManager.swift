import AppKit

enum IconTransition: String, Codable {
    case off    // no animation, instant swap
    case flow   // coverflow: proportional scale, slide left-to-right
    case pages  // page flip: squeeze X only, old exits right, new enters left
    case cards  // card flip: squeeze X to center axis, expand from center
}

@MainActor
class IconManager {
    private weak var button: NSStatusBarButton?

    var iconsDir: String?
    var transitionConfig: IconTransition?
    private var cache: [String: NSImage] = [:]
    private var oldOverlay: NSImageView?
    private var newOverlay: NSImageView?
    private var animating = false

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    var effectiveTransition: IconTransition {
        if let explicit = transitionConfig { return explicit }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .off : .pages
    }

    // MARK: - Public

    func updateAnimated(for state: AppState) {
        guard let button else {
            updateIcon(for: state)
            return
        }

        let newImage = nextImage(for: state)

        guard newImage != button.image else { return }

        if effectiveTransition == .off {
            updateIcon(for: state)
            return
        }

        if animating {
            cancelAnimation()
        }

        slideTo(newImage, for: state)
    }

    func updateIcon(for state: AppState) {
        guard let button else { return }
        switch state {
        case .stopped, .starting, .restarting:
            if let image = loadPlaceholder() {
                button.image = image
            } else {
                button.image = makeTextBadge(NSLocalizedString("status.placeholder", comment: ""))
            }
        case .running(let layer):
            if let dir = iconsDir, let image = loadIcon(layer: layer, from: dir) {
                button.image = image
            } else {
                button.image = makeTextBadge(String(layer.prefix(1)).uppercased())
            }
        }
    }

    func nextImage(for state: AppState) -> NSImage? {
        switch state {
        case .stopped, .starting, .restarting:
            return loadPlaceholder()
        case .running(let layer):
            if let dir = iconsDir { return loadIcon(layer: layer, from: dir) }
            return nil
        }
    }

    // MARK: - Animation

    private func slideTo(_: NSImage?, for state: AppState) {
        guard let button else { return }

        animating = true

        button.wantsLayer = true
        button.layer?.masksToBounds = true
        let bounds = button.bounds

        let oldSnapshot = snapshotButton(button)

        updateIcon(for: state)
        let newSnapshot = snapshotButton(button)
        button.image = nil

        let oldView = NSImageView()
        oldView.image = oldSnapshot
        oldView.frame = bounds
        button.addSubview(oldView)

        let newView = NSImageView()
        newView.image = newSnapshot
        newView.frame = bounds
        newView.alphaValue = 0.0
        button.addSubview(newView)

        oldOverlay = oldView
        newOverlay = newView

        let scaling: NSImageScaling = effectiveTransition == .flow ? .scaleProportionallyDown : .scaleAxesIndependently
        oldView.imageScaling = scaling
        newView.imageScaling = scaling

        let oldEndFrame: NSRect
        let newStartFrame: NSRect

        switch effectiveTransition {
        case .off:
            return

        case .flow, .pages:
            newStartFrame = NSRect(x: bounds.minX, y: bounds.minY, width: 0, height: bounds.height)
            oldEndFrame = NSRect(x: bounds.maxX, y: bounds.minY, width: 0, height: bounds.height)

        case .cards:
            let midX = bounds.midX
            newStartFrame = NSRect(x: midX, y: bounds.minY, width: 0, height: bounds.height)
            oldEndFrame = NSRect(x: midX, y: bounds.minY, width: 0, height: bounds.height)
        }

        newView.frame = newStartFrame

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            oldView.animator().frame = oldEndFrame
            oldView.animator().alphaValue = 0.0

            newView.animator().frame = bounds
            newView.animator().alphaValue = 1.0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.oldOverlay === oldView else { return }
                self.finishAnimation(for: state)
            }
        })
    }

    private func cleanupOverlays() {
        oldOverlay?.removeFromSuperview()
        newOverlay?.removeFromSuperview()
        oldOverlay = nil
        newOverlay = nil
    }

    private func cancelAnimation() {
        cleanupOverlays()
        animating = false
    }

    private func finishAnimation(for state: AppState) {
        cleanupOverlays()
        updateIcon(for: state)
        animating = false
    }

    private func snapshotButton(_ button: NSButton) -> NSImage {
        let bounds = button.bounds
        guard let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        button.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Icon Loading

    private func loadPlaceholder() -> NSImage? {
        if let cached = cache["__placeholder"] { return cached }

        guard let path = Bundle.main.path(forResource: "placeholder", ofType: "png"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Kanata Bar"
        cache["__placeholder"] = image
        return image
    }

    private func loadIcon(layer: String, from dir: String) -> NSImage? {
        if let cached = cache[layer] { return cached }

        let path = "\(dir)/\(layer).png"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Kanata Bar"
        cache[layer] = image
        return image
    }

    private func makeTextBadge(_ text: String) -> NSImage {
        let emoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation }

        if emoji {
            return makeEmojiBadge(text)
        }

        let size: CGFloat = 18
        let cornerRadius: CGFloat = 3
        let font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 11), toHaveTrait: .boldFontMask
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let borderRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = 1
            NSColor.black.setStroke()
            path.stroke()

            let x = (size - textSize.width) / 2
            let y = (size - textSize.height) / 2
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kanata Bar"
        return image
    }

    private func makeEmojiBadge(_ text: String) -> NSImage {
        let size: CGFloat = 18
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pxSize = Int(size * scale)
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: size, height: size)
        let x = (size - textSize.width) / 2
        let y = (size - textSize.height) / 2

        // 1. Render emoji + shadow into offscreen bitmap
        guard let bCtx = CGContext(data: nil, width: pxSize, height: pxSize,
                                    bitsPerComponent: 8, bytesPerRow: pxSize * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: imageSize) }

        bCtx.scaleBy(x: scale, y: scale)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bCtx, flipped: false)

        bCtx.setShadow(offset: .zero, blur: 3.6, color: CGColor(gray: 0, alpha: 1))
        for _ in 0..<3 {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        NSGraphicsContext.current = prev

        // 2. Threshold alpha → crisp outline
        if let data = bCtx.data {
            let px = data.bindMemory(to: UInt8.self, capacity: pxSize * pxSize * 4)
            for i in 0..<(pxSize * pxSize) {
                let a = i * 4 + 3
                px[a] = min(255, UInt8(min(Int(px[a]) * 8, 255)))
            }
        }

        guard let outlineCG = bCtx.makeImage() else { return NSImage(size: imageSize) }

        // 3. Composite: tinted outline + color emoji
        let image = NSImage(size: imageSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            let rect = CGRect(origin: .zero, size: imageSize)

            // Subtle drop shadow behind the sticker
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2.0, color: CGColor(gray: 0, alpha: 0.4))

            // Outline + emoji drawn inside shadow scope
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)

            // White outline
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.draw(outlineCG, in: rect)
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            // Color emoji on top
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            ctx.endTransparencyLayer()

            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Kanata Bar"
        return image
    }
}
