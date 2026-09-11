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
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Global shortcut for toggling "Prevent Sleep": ⌃⌥⌘L. Chosen to be
    /// unlikely to collide with system or third-party app shortcuts.
    private static let hotKeyCode = UInt32(kVK_ANSI_L)
    private static let hotKeyModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let hotKeyDisplayString = "⌃⌥⌘L"
    private static let modeDefaultsKey = "de.olau.lucid.sleepPreventionMode"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let powerManager = PowerAssertionManager()
    private let dimController = DisplayDimController()
    private let didSetUpLoginItemDefaultsKey = "de.olau.lucid.didSetUpLoginItem"
    private var screenWakeObserver: NSObjectProtocol?
    private var hotKeyManager: HotKeyManager?

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
                dimController.dim()
            }
        } else {
            powerManager.stop()
            if dimController.isDimmed {
                dimController.restore()
            }
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
    }

    private func updateModeMenuState() {
        turnOffModeItem.state = mode == .turnOffDisplay ? .on : .off
        dimModeItem.state = mode == .dimDisplay ? .on : .off
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
