import AppKit
import Carbon
import IOKit.hid

/// Owns the HUD keyboard: panel, state, event tap, config parsing and the
/// input-source observer. The app delegate feeds it kanata's TCP events.
@MainActor
final class HudController {
    static let visibleDefaultsKey = "hudVisible"

    private(set) var state: HudState
    private let glyphs: InputSourceGlyphs
    private var view: HudKeyboardView
    private var panel: HudPanel?
    private let tap = InputTap()
    private var tickTimer: Timer?
    private var tapRetryTimer: Timer?
    private var configPath: String
    private var tapWarned = false

    /// Config path kanata is running with; re-read on every reload.
    var kanataConfigPath: String {
        get { configPath }
        set { configPath = newValue }
    }

    init(configPath: String, geometry: KeyboardLayoutKind?) {
        self.configPath = configPath
        glyphs = InputSourceGlyphs()
        let kind = geometry ?? Self.detectGeometry()
        state = HudState(geometry: .make(kind), resolver: LabelResolver(glyphs: glyphs))
        view = HudKeyboardView(state: state)
        state.onChange = { [weak self] in self?.view.refresh() }
        Logging.log("HUD geometry: \(kind.rawValue)\(geometry == nil ? " (auto)" : ""), input source: \(InputSourceGlyphs.currentSourceID())")

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }

    // MARK: - Visibility

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil {
            panel = HudPanel(contentView: view)
        }
        reloadConfig()
        panel?.orderFrontRegardless()
        startTapWhenTrusted()
        startTicking()
        UserDefaults.standard.set(true, forKey: Self.visibleDefaultsKey)
    }

    func hide() {
        panel?.orderOut(nil)
        tap.stop()
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        stopTicking()
        UserDefaults.standard.set(false, forKey: Self.visibleDefaultsKey)
    }

    /// A tap created before Accessibility is granted stays crippled for its
    /// lifetime (it only sees events aimed at this app), so wait for the grant
    /// and only then create it. Always a fresh tap per show().
    private func startTapWhenTrusted() {
        tap.stop()
        guard TCCPermissions.isGranted(.accessibility) else {
            if !tapWarned {
                tapWarned = true
                Logging.log("HUD: waiting for Accessibility before installing the event tap")
            }
            tapRetryTimer?.invalidate()
            tapRetryTimer = Timer.scheduledTimer(withTimeInterval: Timing.hudTapRetry, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, TCCPermissions.isGranted(.accessibility) else { return }
                    self.tapRetryTimer?.invalidate()
                    self.tapRetryTimer = nil
                    self.startTapWhenTrusted()
                }
            }
            return
        }
        tap.onEvent = { [weak self] event in self?.state.input(event) }
        tap.onDisabled = { Logging.log("HUD: event tap was disabled by the system, re-enabled") }
        if tap.start() {
            Logging.log("HUD: event tap installed")
        } else {
            Logging.log("HUD: event tap refused by the system")
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    static var wasVisibleLastTime: Bool {
        UserDefaults.standard.bool(forKey: visibleDefaultsKey)
    }

    // MARK: - kanata events

    func layerChanged(_ layer: String) {
        state.setLayer(layer)
    }

    func kanataStopped() {
        state.kanataStopped()
    }

    func holdActivated(_ key: String) {
        state.holdActivated(tcpKey: key)
        startTicking()
    }

    func tapActivated(_ key: String) {
        state.tapActivated(tcpKey: key)
        startTicking()
    }

    func reloadConfig() {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            Logging.log("HUD: cannot read kanata config at \(configPath)")
            state.setLayout(nil)
            return
        }
        let baseDir = (configPath as NSString).deletingLastPathComponent
        do {
            let layout = try KanataConfigParser().parse(text: text, baseDir: baseDir)
            state.setLayout(layout)
            Logging.log("HUD: parsed config — \(layout.sourceKeys.count) src keys, layers: \(layout.layerNames.joined(separator: ", "))")
        } catch {
            Logging.log("HUD: config parse failed: \(error)")
            state.setLayout(nil)
        }
    }

    @objc private func inputSourceChanged() {
        glyphs.reload()
        state.relabel()
    }

    // MARK: - Housekeeping

    private func startTicking() {
        guard isVisible, tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: Timing.hudTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.tick()
                if !self.state.hasTransientState { self.stopTicking() }
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Geometry detection

    /// ISO when any attached physical keyboard reports HID country code 13
    /// (ISO); ANSI otherwise. Karabiner's virtual keyboard is skipped — it always
    /// claims ANSI regardless of the physical board.
    static func detectGeometry() -> KeyboardLayoutKind {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return .ansi }
        for device in devices {
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
            if product.lowercased().contains("karabiner") { continue }
            guard let code = IOHIDDeviceGetProperty(device, kIOHIDCountryCodeKey as CFString) as? Int else { continue }
            if code == 13 { return .iso }
        }
        return .ansi
    }
}
