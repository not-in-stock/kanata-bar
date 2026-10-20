import Foundation

/// Per-key visual state the HUD renders, derived from kanata's TCP stream and
/// the OS event tap. Pure logic; the view reads it, the controller feeds it.
@MainActor
final class HudState {
    enum HoldEnd: Equatable {
        /// Ends when this modifier's device flag clears.
        case modifier(bit: UInt64)
        /// Ends when the active layer stops being this one.
        case layer(String)
        /// No observable end: expires after `Timing.hudHoldFallback`.
        case timeout
    }

    struct Hold: Equatable {
        let end: HoldEnd
        let since: Date
        /// For `.layer`: whether the LayerChange to the target was seen yet.
        var armed: Bool
    }

    private(set) var layout: KanataLayout?
    /// Active kanata layer; nil while kanata isn't running.
    private(set) var layer: String?
    /// Keycodes currently down according to the OS (kanata output).
    private(set) var pressed: Set<Int> = []
    /// Source keys whose tap-hold is in its hold state.
    private(set) var holds: [String: Hold] = [:]
    /// Source keys that just resolved as a tap (flash).
    private(set) var tapFlashes: [String: Date] = [:]
    /// Labels per kanata key name for the current layer and input source.
    private(set) var labels: [String: KeyLabel] = [:]

    var resolver: LabelResolver
    var geometry: KeyboardGeometry
    var onChange: (() -> Void)?
    var now: () -> Date = Date.init

    init(geometry: KeyboardGeometry, resolver: LabelResolver) {
        self.geometry = geometry
        self.resolver = resolver
        relabel()
    }

    // MARK: - Inputs

    func setLayout(_ layout: KanataLayout?) {
        self.layout = layout
        relabel()
    }

    func setLayer(_ newLayer: String?) {
        let old = layer
        layer = newLayer
        // Layer holds end when the layer moves off their target.
        for (key, hold) in holds {
            guard case .layer(let target) = hold.end else { continue }
            if newLayer == target {
                holds[key]?.armed = true
            } else if hold.armed || newLayer == nil {
                holds[key] = nil
            }
        }
        if newLayer == nil {
            holds.removeAll()
            tapFlashes.removeAll()
        }
        if old != newLayer { relabel() } else { onChange?() }
    }

    func kanataStopped() {
        setLayer(nil)
    }

    func holdActivated(tcpKey: String) {
        guard let key = KeyNames.byTCPName[tcpKey]?.name ?? KeyNames.canonical(tcpKey) else { return }
        let end: HoldEnd
        if let layout, let layer, case .tapHold(_, let hold) = layout.action(layer: layer, key: key) {
            switch hold {
            case .key(let name, _) where KeyNames.byName[name]?.isModifier == true:
                end = .modifier(bit: KeyNames.byName[name]!.modifierBit)
            case .layerWhileHeld(let target):
                end = .layer(target)
            default:
                end = .timeout
            }
        } else {
            end = .timeout
        }
        holds[key] = Hold(end: end, since: now(), armed: false)
        tapFlashes[key] = nil
        onChange?()
    }

    func tapActivated(tcpKey: String) {
        guard let key = KeyNames.byTCPName[tcpKey]?.name ?? KeyNames.canonical(tcpKey) else { return }
        holds[key] = nil
        tapFlashes[key] = now()
        onChange?()
    }

    func input(_ event: InputEvent) {
        switch event {
        case .keyDown(let keycode):
            pressed.insert(keycode)
        case .keyUp(let keycode):
            pressed.remove(keycode)
        case .modifier(let keycode, let down, let flags):
            if down { pressed.insert(keycode) } else { pressed.remove(keycode) }
            // Modifier holds end when their device flag is gone (after a short
            // grace: kanata's modifier DOWN and HoldActivated can arrive in either order).
            let t = now()
            for (key, hold) in holds {
                guard case .modifier(let bit) = hold.end, flags & bit == 0,
                      t.timeIntervalSince(hold.since) > Timing.hudHoldGrace else { continue }
                holds[key] = nil
            }
        }
        onChange?()
    }

    /// Drops expired flashes and timed-out holds. Returns true if anything changed.
    @discardableResult
    func tick() -> Bool {
        let t = now()
        let flashesBefore = tapFlashes.count
        tapFlashes = tapFlashes.filter { t.timeIntervalSince($0.value) < Timing.hudTapFlash }
        let holdsBefore = holds.count
        holds = holds.filter { _, hold in
            let age = t.timeIntervalSince(hold.since)
            if case .timeout = hold.end { return age < Timing.hudHoldFallback }
            return age < Timing.hudHoldHardLimit
        }
        let changed = flashesBefore != tapFlashes.count || holdsBefore != holds.count
        if changed { onChange?() }
        return changed
    }

    func relabel() {
        var out: [String: KeyLabel] = [:]
        for cap in geometry.caps {
            guard let name = cap.name else { continue }
            out[name] = resolver.label(for: name, layout: layout, layer: layer)
        }
        labels = out
        onChange?()
    }

    // MARK: - Queries for the view

    func isPressed(_ key: String) -> Bool {
        guard let code = KeyNames.byName[key]?.keycode else { return false }
        return pressed.contains(code)
    }

    func isHoldActive(_ key: String) -> Bool { holds[key] != nil }

    func isTapFlashing(_ key: String) -> Bool { tapFlashes[key] != nil }

    var hasTransientState: Bool { !tapFlashes.isEmpty || !holds.isEmpty }
}
