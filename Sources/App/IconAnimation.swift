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

        // Skip if nothing changed
        guard newImage != button.image else {
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

        slideTo(newImage)
    }

    private func slideTo(_ newImage: NSImage?) {
        guard let button = statusItem?.button else { return }

        iconAnimating = true

        button.wantsLayer = true
        button.layer?.masksToBounds = true
        let bounds = button.bounds

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

    private func cleanupOverlays() {
        iconOldOverlay?.removeFromSuperview()
        iconNewOverlay?.removeFromSuperview()
        iconOldOverlay = nil
        iconNewOverlay = nil
    }

    private func cancelIconAnimation() {
        cleanupOverlays()
        iconAnimating = false
        updateIcon()
    }

    private func finishIconAnimation() {
        cleanupOverlays()
        updateIcon()
        iconAnimating = false
    }

    func snapshotButton(_ button: NSButton) -> NSImage {
        let bounds = button.bounds
        guard let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        button.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
