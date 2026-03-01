import AppKit

enum IconTransition: String, Codable {
    case off    // no animation, instant swap
    case flow   // coverflow: proportional scale, slide left-to-right
    case pages  // page flip: squeeze X only, old exits right, new enters left
    case cards  // card flip: squeeze X to center axis, expand from center
}

extension AppDelegate {
    func updateIconAnimated() {
        guard let button = statusItem?.button else {
            updateIcon()
            return
        }

        let newImage = nextImage()
        let newTitle = nextTitle()

        // Skip if nothing changed
        guard newImage != button.image || newTitle != button.title else {
            return
        }

        if iconTransition == .off {
            updateIcon()
            return
        }

        // Cancel in-flight animation and start new one
        if iconAnimating {
            cancelIconAnimation()
        }

        slideTo(newImage, title: newTitle)
    }

    private func slideTo(_ newImage: NSImage?, title newTitle: String) {
        guard let button = statusItem?.button else { return }

        iconAnimating = true

        button.wantsLayer = true
        button.layer?.masksToBounds = true
        let bounds = button.bounds

        let iconSize: CGFloat = 18
        let iy = (bounds.height - iconSize) / 2
        let iconRect = NSRect(x: (bounds.width - iconSize) / 2, y: iy, width: iconSize, height: iconSize)

        // Snapshot old state
        let oldSnapshot = snapshotButton(button)

        // Set new content, snapshot it, then hide
        updateIcon()
        let newSnapshot = snapshotButton(button)
        button.image = nil
        button.title = ""

        // Now add overlays
        let oldView = NSImageView()
        oldView.image = oldSnapshot
        oldView.frame = bounds
        button.addSubview(oldView)

        let newView = NSImageView()
        newView.image = newSnapshot
        newView.frame = bounds
        newView.alphaValue = 0.0
        button.addSubview(newView)

        iconOldOverlay = oldView
        iconNewOverlay = newView

        let scaling: NSImageScaling = iconTransition == .flow ? .scaleProportionallyDown : .scaleAxesIndependently
        oldView.imageScaling = scaling
        newView.imageScaling = scaling

        let oldEndFrame: NSRect
        let newStartFrame: NSRect

        switch iconTransition {
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
        }, completionHandler: { [weak self] in
            guard let self, self.iconOldOverlay === oldView else { return }
            self.finishIconAnimation()
        })
    }

    private func cancelIconAnimation() {
        // Remove overlays immediately — stops visual animation
        iconOldOverlay?.removeFromSuperview()
        iconNewOverlay?.removeFromSuperview()
        iconOldOverlay = nil
        iconNewOverlay = nil
        iconAnimating = false
        updateIcon()
    }

    private func finishIconAnimation() {
        iconOldOverlay?.removeFromSuperview()
        iconNewOverlay?.removeFromSuperview()
        iconOldOverlay = nil
        iconNewOverlay = nil
        updateIcon()
        iconAnimating = false
    }

    private func makeTextBadge(_ text: String) -> NSImage {
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
            // Rounded rect border (1px inset so the stroke is fully inside)
            let borderRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = 1
            NSColor.black.setStroke()
            path.stroke()

            // Centered text
            let x = (size - textSize.width) / 2
            let y = (size - textSize.height) / 2
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
        return image
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

    private func makeLabel(_ text: String) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = NSFont.menuBarFont(ofSize: 0)
        tf.alignment = .center
        tf.wantsLayer = true
        tf.layer?.masksToBounds = true
        return tf
    }

    private func nextImage() -> NSImage? {
        switch appState {
        case .stopped, .starting, .restarting:
            return loadPlaceholder()
        case .running(let layer):
            if let dir = iconsDir { return loadIcon(layer: layer, from: dir) }
            return nil
        }
    }

    private func nextTitle() -> String {
        switch appState {
        case .stopped, .starting, .restarting:
            return nextImage() != nil ? "" : NSLocalizedString("status.placeholder", comment: "")
        case .running(let layer):
            if let dir = iconsDir, loadIcon(layer: layer, from: dir) != nil { return "" }
            return String(layer.prefix(1)).uppercased()
        }
    }

    func updateIcon() {
        switch appState {
        case .stopped, .starting, .restarting:
            if let image = loadPlaceholder() {
                statusItem?.button?.image = image
                statusItem?.button?.title = ""
            } else {
                statusItem?.button?.image = nil
                statusItem?.button?.image = makeTextBadge(NSLocalizedString("status.placeholder", comment: ""))
                statusItem?.button?.title = ""
            }
        case .running(let layer):
            if let dir = iconsDir, let image = loadIcon(layer: layer, from: dir) {
                statusItem.button?.image = image
                statusItem.button?.title = ""
            } else {
                statusItem.button?.image = makeTextBadge(String(layer.prefix(1)).uppercased())
                statusItem.button?.title = ""
            }
        }

    }

    func loadPlaceholder() -> NSImage? {
        if let cached = iconCache["__placeholder"] { return cached }

        let candidates = [
            iconsDir.map { "\($0)/placeholder.png" },
            Bundle.main.path(forResource: "placeholder", ofType: "png")
        ].compactMap { $0 }

        for path in candidates {
            if let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                iconCache["__placeholder"] = image
                return image
            }
        }
        return nil
    }

    func loadIcon(layer: String, from dir: String) -> NSImage? {
        if let cached = iconCache[layer] { return cached }

        let path = "\(dir)/\(layer).png"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        iconCache[layer] = image
        return image
    }
}
