import AppKit

class LayerRollerView: NSView {
    private let prefixLabel: NSTextField
    private var currentLabel: NSTextField
    private var nextLabel: NSTextField
    private var currentCenterY: NSLayoutConstraint!
    private var nextCenterY: NSLayoutConstraint!
    private var currentText = ""
    private var isAnimating = false
    private var pendingLayer: String?
    private let viewHeight: CGFloat = 22
    private var leadingConstraint: NSLayoutConstraint!

    init(prefix: String, width: CGFloat = 200) {
        prefixLabel = NSTextField(labelWithString: prefix)
        currentLabel = NSTextField(labelWithString: "")
        nextLabel = NSTextField(labelWithString: "")
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
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            label.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 0).isActive = true
        }

        currentCenterY = currentLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        currentCenterY.isActive = true

        // Next label starts above (offset by height)
        nextCenterY = nextLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -viewHeight)
        nextCenterY.isActive = true
        nextLabel.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLeading(_ constant: CGFloat) {
        leadingConstraint.constant = constant
    }

    func update(layer: String, animated: Bool) {
        guard layer != currentText else { return }
        setAccessibilityLabel("\(prefixLabel.stringValue)\(layer)")

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
            finishAnimation()

            if let pending = pendingLayer {
                pendingLayer = nil
                if pending != currentText {
                    currentText = pending
                    animateTo(pending)
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
