import AppKit
import Carbon.HIToolbox

/// How "Prevent Sleep" affects the display while active.
enum SleepPreventionMode: Int {
    /// Turn the display off immediately via `pmset displaysleepnow`
    /// (`DisplayController`). Maximum power saving, but macOS/the SoC
    /// appears to drop into a lower CPU performance state when no
    /// display is actively signaling – see the README.
    case turnOffDisplay
    /// Dim the display to near-minimum brightness instead
    /// (`DisplayDimController`). The display stays logically "on", which
    /// should avoid that reduced-performance state, at the cost of a
    /// faint but nonzero glow and less certain hardware support
    /// (external displays depend on DDC/CI).
    case dimDisplay
    /// Show a full-screen CPU/GPU activity chart (`ActivityOverlayController`)
    /// – a screensaver rather than a power saver. Since the display stays
    /// fully lit and actively rendering, this sidesteps the
    /// reduced-performance state by construction, saving much less power
    /// than the other two modes. Still dims the hardware brightness to
    /// the configured Dim Level first (`DimStyle.screensaver`) rather
    /// than showing the chart at full brightness – gamma is left alone
    /// so the chart's own colors stay legible.
    case showActivityMonitor
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Global shortcut for toggling "Prevent Sleep": ⌃⌥⌘L. Chosen to be
    /// unlikely to collide with system or third-party app shortcuts.
    private static let hotKeyCode = UInt32(kVK_ANSI_L)
    private static let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let hotKeyDisplayString = "⌃⌥⌘L"
    private static let modeDefaultsKey = "de.olau.lucid.sleepPreventionMode"
    private static let dimGammaCeilingDefaultsKey = "de.olau.lucid.dimGammaCeiling"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let powerManager = PowerAssertionManager()
    private let dimController = DisplayDimController()
    private let activityOverlayController = ActivityOverlayController()
    private let didSetUpLoginItemDefaultsKey = "de.olau.lucid.didSetUpLoginItem"
    private var screenWakeObserver: NSObjectProtocol?
    private var hotKeyManager: HotKeyManager?

    /// Auto-restores "Dim Display"/"Show Activity Monitor" on keyboard or
    /// mouse activity, the same way `screenWakeObserver` auto-restores
    /// "Turn Display Off" – started only while one of those two modes is
    /// actually active, since neither ever puts the display to sleep for
    /// `screensDidWakeNotification` to fire on. See `IdleActivityMonitor`'s
    /// doc comment for why this needs no extra permission despite covering
    /// the keyboard too.
    private lazy var idleActivityMonitor = IdleActivityMonitor { [weak self] in
        guard let self, self.powerManager.isActive else { return }
        self.setActive(false)
    }

    /// Persisted choice of what "Prevent Sleep" actually does. Switching
    /// modes is only allowed while inactive (see `updateUI`) so we never
    /// have to reconcile e.g. an already-sleeping display with a
    /// newly-selected dim mode.
    private var mode: SleepPreventionMode {
        get {
            SleepPreventionMode(rawValue: UserDefaults.standard.integer(forKey: Self.modeDefaultsKey)) ?? .turnOffDisplay
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeDefaultsKey)
            updateModeMenuState()
        }
    }

    /// Persisted choice of how dark "Dim Display"/"Show Activity Monitor"
    /// make every display (see `DimLevel`). Like `mode`, only changeable
    /// while inactive. Reads via `object(forKey:) as? Double` rather than
    /// `double(forKey:)`, whose default of 0.0 would silently mean "never
    /// configured" and "pitch black" the same thing.
    private var dimGammaCeiling: CGGammaValue {
        get {
            let stored = UserDefaults.standard.object(forKey: Self.dimGammaCeilingDefaultsKey) as? Double
            return stored.map(CGGammaValue.init) ?? DimLevel.defaultCeiling
        }
        set {
            let clamped = max(DimLevel.minCeiling, min(DimLevel.maxCeiling, newValue))
            UserDefaults.standard.set(Double(clamped), forKey: Self.dimGammaCeilingDefaultsKey)
            updateDimLevelSliderState()
        }
    }

    private lazy var toggleItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Prevent Sleep  \(Self.hotKeyDisplayString)",
            action: #selector(toggleActive),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }()

    /// Mode picker, styled as two mutually exclusive checkmarks (AppKit
    /// menus have no distinct "radio button" glyph; this is the standard
    /// convention, e.g. used by "Sort By" style menus).
    private lazy var turnOffModeItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Turn Display Off",
            action: #selector(selectTurnOffMode),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }()

    private lazy var dimModeItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Dim Display",
            action: #selector(selectDimMode),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }()

    private lazy var activityMonitorModeItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Show Activity Monitor",
            action: #selector(selectActivityMonitorMode),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }()

    /// Live "N%" readout next to `dimLevelSlider`, kept in sync by
    /// `updateDimLevelSliderState()`.
    private lazy var dimLevelValueLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }()

    /// Continuous (not `isContinuous = false`) slider over `DimLevel`'s
    /// range, replacing what used to be three fixed presets – see
    /// `DimLevel`'s doc comment for why a few fixed points weren't
    /// granular enough.
    private lazy var dimLevelSlider: NSSlider = {
        let slider = NSSlider(
            value: Double(dimGammaCeiling),
            minValue: Double(DimLevel.minCeiling),
            maxValue: Double(DimLevel.maxCeiling),
            target: self,
            action: #selector(dimLevelSliderChanged(_:))
        )
        slider.isContinuous = true
        return slider
    }()

    /// Custom-view menu item hosting `dimLevelSlider`. Laid out with
    /// explicit frames rather than Auto Layout constraints – NSMenu
    /// doesn't reliably run a full layout pass for custom item views, so
    /// a fixed frame is the more predictable choice here.
    private lazy var dimLevelItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = makeDimLevelView()
        return item
    }()

    private func makeDimLevelView() -> NSView {
        let width: CGFloat = 240
        let height: CGFloat = 54
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Dim Level")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 14, y: height - 22, width: width - 28, height: 16)
        container.addSubview(title)

        dimLevelValueLabel.frame = NSRect(x: width - 14 - 36, y: 6, width: 36, height: 16)
        container.addSubview(dimLevelValueLabel)

        dimLevelSlider.frame = NSRect(x: 14, y: 4, width: width - 28 - 44, height: 20)
        container.addSubview(dimLevelSlider)

        return container
    }

    private lazy var loginItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        configureMenu()
        loginItem.state = LoginItemManager.isEnabled ? .on : .off

        registerLoginItemOnFirstLaunch()
        observeScreenWake()
        registerHotKey()
        updateModeMenuState()
        updateDimLevelSliderState()

        // Start deliberately inactive: the display should only be turned
        // off immediately on an explicit click, not unexpectedly on
        // (possibly automatic) app launch.
        updateUI(active: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerManager.stop()
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
        stopIdleActivityMonitoring()
    }

    /// Turns "Prevent Sleep" back off automatically once the display wakes
    /// up (key press / mouse move). Without this, the user would have to
    /// uncheck it manually before a single click could put the display
    /// back to sleep again.
    private func observeScreenWake() {
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.powerManager.isActive else { return }
            self.setActive(false)
        }
    }

    private func startIdleActivityMonitoring() {
        idleActivityMonitor.start()
    }

    private func stopIdleActivityMonitoring() {
        idleActivityMonitor.stop()
    }

    /// Registers the global ⌃⌥⌘L shortcut so "Prevent Sleep" can be
    /// toggled from any app, not just from this menu. Uses the classic
    /// Carbon hot key API, which – unlike an `NSEvent` global monitor –
    /// doesn't require Accessibility/Input Monitoring permission.
    private func registerHotKey() {
        hotKeyManager = HotKeyManager(
            keyCode: Self.hotKeyCode,
            modifiers: Self.hotKeyModifiers
        ) { [weak self] in
            self?.toggleActive()
        }
    }

    /// Registers the app as a login item automatically on the very first
    /// launch. Runs only once (tracked via a UserDefaults flag) – if the
    /// user removes the entry again via the menu afterwards, it will not
    /// be re-added on the next launch.
    private func registerLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSetUpLoginItemDefaultsKey) else { return }
        defaults.set(true, forKey: didSetUpLoginItemDefaultsKey)

        guard !LoginItemManager.isEnabled else {
            loginItem.state = .on
            return
        }

        do {
            try LoginItemManager.setEnabled(true)
            loginItem.state = .on
        } catch {
            presentLoginItemRegistrationFailureAlert(error)
        }
    }

    // MARK: - UI setup

    private func configureStatusItem() {
        statusItem.button?.image = statusImage(active: false)
    }

    private func configureMenu() {
        // No separate text status line: the checkmark on `toggleItem`
        // already says whether sleep prevention is on, and any label
        // claiming something about the display's current state is moot
        // anyway – if you can read this menu, the display is on.
        let menu = NSMenu()
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(turnOffModeItem)
        menu.addItem(dimModeItem)
        menu.addItem(activityMonitorModeItem)
        menu.addItem(dimLevelItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleActive() {
        setActive(!powerManager.isActive)
    }

    private func setActive(_ active: Bool) {
        if active {
            // 1. Prevent sleep (system stays awake) before touching the
            //    display – otherwise the machine could theoretically fall
            //    asleep between the two steps.
            guard powerManager.start() else {
                presentAssertionFailureAlert()
                updateUI(active: false)
                return
            }
            // 2. Apply the selected mode immediately instead of waiting
            //    for the configured display-sleep timer.
            switch mode {
            case .turnOffDisplay:
                do {
                    try DisplayController.sleepNow()
                } catch {
                    presentDisplaySleepFailureAlert(error)
                    // Sleep protection stays active regardless.
                }
            case .dimDisplay:
                dimController.dim(.blackout(gammaCeiling: dimGammaCeiling))
                startIdleActivityMonitoring()
            case .showActivityMonitor:
                dimController.dim(.screensaver(brightness: Float(dimGammaCeiling)))
                activityOverlayController.show()
                startIdleActivityMonitoring()
            }
        } else {
            powerManager.stop()
            if dimController.isDimmed {
                dimController.restore()
            }
            if activityOverlayController.isShowing {
                activityOverlayController.hide()
            }
            stopIdleActivityMonitoring()
        }
        updateUI(active: active)
    }

    private func updateUI(active: Bool) {
        statusItem.button?.image = statusImage(active: active)
        toggleItem.state = active ? .on : .off
        // Switching modes while active would need to reconcile an
        // already-applied mode (e.g. an already-sleeping display) with a
        // newly-selected one, so only allow it while inactive.
        turnOffModeItem.isEnabled = !active
        dimModeItem.isEnabled = !active
        activityMonitorModeItem.isEnabled = !active
        // Changing the dim level while already dimmed/showing wouldn't
        // visibly apply until the next dim/restore cycle anyway (see
        // `DisplayDimController.dim(_:)`), so keep it disabled while
        // active for the same reason as the mode picker above.
        // NSMenuItem.isEnabled has no effect on a custom `view`'s own
        // controls, so the slider itself needs disabling too.
        dimLevelItem.isEnabled = !active
        dimLevelSlider.isEnabled = !active
    }

    private func updateModeMenuState() {
        turnOffModeItem.state = mode == .turnOffDisplay ? .on : .off
        dimModeItem.state = mode == .dimDisplay ? .on : .off
        activityMonitorModeItem.state = mode == .showActivityMonitor ? .on : .off
    }

    private func updateDimLevelSliderState() {
        dimLevelSlider.doubleValue = Double(dimGammaCeiling)
        dimLevelValueLabel.stringValue = "\(Int(round(dimGammaCeiling * 100)))%"
    }

    private func statusImage(active: Bool) -> NSImage? {
        let symbolName = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let description = active ? "Sleep protection active" : "Sleep protection inactive"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    @objc private func selectTurnOffMode() {
        mode = .turnOffDisplay
    }

    @objc private func selectDimMode() {
        mode = .dimDisplay
    }

    @objc private func selectActivityMonitorMode() {
        mode = .showActivityMonitor
    }

    @objc private func dimLevelSliderChanged(_ sender: NSSlider) {
        dimGammaCeiling = CGGammaValue(sender.doubleValue)
    }

    @objc private func toggleLoginItem() {
        let newState = loginItem.state != .on
        do {
            try LoginItemManager.setEnabled(newState)
            loginItem.state = newState ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Change Login Item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func presentAssertionFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Could Not Prevent Sleep"
        alert.informativeText = "The system rejected the request to prevent sleep."
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func presentDisplaySleepFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Turn Off Display"
        alert.informativeText = "\(error.localizedDescription)\n\nSleep protection is still active."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func presentLoginItemRegistrationFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Add Login Item"
        alert.informativeText = "\(error.localizedDescription)\n\nYou can enable \u{201c}Start at Login\u{201d} manually from the menu at any time."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
