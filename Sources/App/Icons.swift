import AppKit

extension AppDelegate {
    func updateIcon() {
        switch appState {
        case .stopped, .starting, .restarting:
            if let image = loadPlaceholder() {
                statusItem?.button?.image = image
                statusItem?.button?.title = ""
            } else {
                statusItem?.button?.image = nil
                statusItem?.button?.title = NSLocalizedString("status.placeholder", comment: "")
            }
        case .running(let layer):
            if let dir = iconsDir, let image = loadIcon(layer: layer, from: dir) {
                statusItem.button?.image = image
                statusItem.button?.title = ""
            } else {
                statusItem.button?.image = nil
                statusItem.button?.title = String(layer.prefix(1)).uppercased()
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
