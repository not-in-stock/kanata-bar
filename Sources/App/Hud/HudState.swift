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
        /// `.layer`: the LayerChange to the target was seen. `.modifier`: the
        /// modifier was seen down — its next release ends the hold.
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
    /// Output key name → caps whose current-layer action produces it (inverse
    /// map, so an output `down` lights the physical `j` that is mapped to it).
    private var producers: [String: [Producer]] = [:]
    private var lastFlags: UInt64 = 0

    private struct Producer: Equatable {
        let cap: String
        /// Produced by a tap-hold's hold branch: counts only while that hold is active.
        let viaHold: Bool
    }

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
            lastFlags = flags
            // A modifier hold ends on the release that follows its press. kanata's
            // modifier DOWN and HoldActivated arrive in either order ~20 ms apart,
            // so a release without a seen press only counts after a grace period.
            let t = now()
            for (key, hold) in holds {
                guard case .modifier(let bit) = hold.end else { continue }
                if flags & bit != 0 {
                    holds[key]?.armed = true
                } else if hold.armed || t.timeIntervalSince(hold.since) > Timing.hudHoldGrace {
                    holds[key] = nil
                }
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
            switch hold.end {
            case .timeout:
                return age < Timing.hudHoldFallback
            case .modifier(let bit):
                // Press+release both inside the grace window leave no later
                // evidence: once the grace is over, a modifier that isn't down is released.
                if age > Timing.hudHoldGrace, lastFlags & bit == 0 { return false }
                return age < Timing.hudHoldHardLimit
            case .layer:
                return age < Timing.hudHoldHardLimit
            }
        }
        let changed = flashesBefore != tapFlashes.count || holdsBefore != holds.count
        if changed { onChange?() }
        return changed
    }

    func relabel() {
        var out: [String: KeyLabel] = [:]
        var prod: [String: [Producer]] = [:]
        for cap in geometry.caps {
            guard let name = cap.name else { continue }
            out[name] = resolver.label(for: name, layout: layout, layer: layer)
            if let layout, let layer, layout.sourceKeys.contains(name) {
                let action = resolver.effectiveAction(for: name, layout: layout, layer: layer)
                for (output, viaHold) in Self.outputs(of: action) where output != name {
                    prod[output, default: []].append(Producer(cap: name, viaHold: viaHold))
                }
            }
        }
        labels = out
        producers = prod
        onChange?()
    }

    /// Key names an action can emit, flagged when they come from a hold branch.
    static func outputs(of action: KanataAction, viaHold: Bool = false) -> [(String, Bool)] {
        switch action {
        case .key(let name, _):
            return [(name, viaHold)]
        case .tapHold(let tap, let hold):
            return outputs(of: tap, viaHold: viaHold) + outputs(of: hold, viaHold: true)
        case .oneShot(let inner):
            return outputs(of: inner, viaHold: viaHold)
        case .fork(let a, let b):
            return outputs(of: a, viaHold: viaHold) + outputs(of: b, viaHold: viaHold)
        case .multi(let list), .tapDance(let list):
            return list.flatMap { outputs(of: $0, viaHold: viaHold) }
        default:
            return []
        }
    }

    // MARK: - Queries for the view

    /// Whether the cap should draw as pressed. Pressed state comes from kanata's
    /// *output*; a cap lights when it produces a pressed output in the current
    /// layer (physical `j` for an output `down` in a nav layer), and the output
    /// key's own cap lights only when no remapped cap claims it. A modifier
    /// emitted by an active home-row hold lights the held cap, not the modifier.
    func isPressed(_ key: String) -> Bool {
        for (output, list) in producers where isOutputDown(output) {
            for p in list where p.cap == key && (!p.viaHold || holds[key] != nil) { return true }
        }
        guard isOutputDown(key) else { return false }
        let claimed = producers[key]?.contains { !$0.viaHold || holds[$0.cap] != nil } ?? false
        return !claimed
    }

    private func isOutputDown(_ key: String) -> Bool {
        guard let code = KeyNames.byName[key]?.keycode, code >= 0 else { return false }
        return pressed.contains(code)
    }

    func isHoldActive(_ key: String) -> Bool { holds[key] != nil }

    func isTapFlashing(_ key: String) -> Bool { tapFlashes[key] != nil }

    var hasTransientState: Bool { !tapFlashes.isEmpty || !holds.isEmpty }
}
