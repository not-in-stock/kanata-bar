import AppKit

private class FadingTextField: NSTextField {
    var fadeWidth: CGFloat = 24

    override func draw(_ dirtyRect: NSRect) {
        let textWidth = intrinsicContentSize.width
        guard textWidth > bounds.width, let context = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }

        let fadeStart = bounds.width - fadeWidth

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        super.draw(dirtyRect)

        context.setBlendMode(.destinationOut)
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: fadeStart, y: 0),
                                       end: CGPoint(x: bounds.width, y: 0),
                                       options: [])
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }
}

class LayerRollerView: NSView {
    private let prefixLabel: NSTextField
    private var currentLabel: FadingTextField
    private var nextLabel: FadingTextField
    private var currentCenterY: NSLayoutConstraint!
    private var nextCenterY: NSLayoutConstraint!
    private var currentText = ""
    private var isAnimating = false
    private var pendingLayer: String?
    private let viewHeight: CGFloat = 22
    private var leadingConstraint: NSLayoutConstraint!
    private let trailingMargin: CGFloat = 14

    init(prefix: String, width: CGFloat = 200) {
        prefixLabel = NSTextField(labelWithString: prefix)
        currentLabel = FadingTextField(labelWithString: "")
        nextLabel = FadingTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: viewHeight))
        wantsLayer = true
        layer?.masksToBounds = true

        prefixLabel.font = NSFont.menuFont(ofSize: 14)
        prefixLabel.textColor = .secondaryLabelColor
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prefixLabel)
        leadingConstraint = prefixLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            leadingConstraint,
            prefixLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        for label in [currentLabel, nextLabel] {
            label.font = NSFont.menuFont(ofSize: 14)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 0),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -trailingMargin),
            ])
        }

        currentCenterY = currentLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        currentCenterY.isActive = true

        // Next label starts above (offset by height)
        nextCenterY = nextLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -viewHeight)
        nextCenterY.isActive = true
        nextLabel.alphaValue = 0

    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityChildren() -> [Any]? { nil }

    func updateLeading(_ constant: CGFloat) {
        leadingConstraint.constant = constant
    }

    func update(layer: String, animated: Bool) {
        guard layer != currentText else { return }
        setAccessibilityLabel(String(format: NSLocalizedString("accessibility.layer", comment: ""), layer))
        NSAccessibility.post(element: self, notification: .valueChanged)

        if !animated || currentText.isEmpty {
            currentText = layer
            finishAnimation()
            currentLabel.stringValue = layer
            return
        }

        if isAnimating {
            pendingLayer = layer
            return
        }

        currentText = layer
        animateTo(layer)
    }

    private func animateTo(_ text: String) {
        isAnimating = true

        // Prepare next label above
        nextLabel.stringValue = text
        nextLabel.alphaValue = 0
        nextCenterY.constant = -viewHeight
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            currentCenterY.constant = viewHeight
            currentLabel.animator().alphaValue = 0

            nextCenterY.constant = 0
            nextLabel.animator().alphaValue = 1

            layoutSubtreeIfNeeded()
        }, completionHandler: { [self] in
            MainActor.assumeIsolated {
                self.finishAnimation()

                if let pending = self.pendingLayer {
                    self.pendingLayer = nil
                    if pending != self.currentText {
                        self.currentText = pending
                        self.animateTo(pending)
                    }
                }
            }
        })
    }

    private func finishAnimation() {
        isAnimating = false

        // Swap so currentLabel is the visible one
        let tmpLabel = currentLabel
        currentLabel = nextLabel
        nextLabel = tmpLabel

        let tmpConstraint = currentCenterY
        currentCenterY = nextCenterY
        nextCenterY = tmpConstraint

        // Reset
        currentCenterY.constant = 0
        currentLabel.alphaValue = 1
        nextLabel.stringValue = ""
        nextLabel.alphaValue = 0
        nextCenterY.constant = -viewHeight
    }

}
