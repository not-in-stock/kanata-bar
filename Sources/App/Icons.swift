import AppKit

extension AppDelegate {
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

    func nextImage() -> NSImage? {
        switch appState {
        case .stopped, .starting, .restarting:
            return loadPlaceholder()
        case .running(let layer):
            if let dir = iconsDir { return loadIcon(layer: layer, from: dir) }
            return nil
        }
    }

    func updateIcon() {
        switch appState {
        case .stopped, .starting, .restarting:
            if let image = loadPlaceholder() {
                statusItem?.button?.image = image
                statusItem?.button?.title = ""
            } else {
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
