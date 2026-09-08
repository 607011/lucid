import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let powerManager = PowerAssertionManager()
    private let didSetUpLoginItemDefaultsKey = "de.olau.lucid.didSetUpLoginItem"

    private lazy var statusLabelItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    private lazy var toggleItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Prevent Sleep",
            action: #selector(toggleActive),
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

        // Start deliberately inactive: the display should only be turned
        // off immediately on an explicit click, not unexpectedly on
        // (possibly automatic) app launch.
        updateUI(active: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerManager.stop()
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
        let menu = NSMenu()
        menu.addItem(statusLabelItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
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
            // 1. Prevent sleep (system stays awake) before turning off the
            //    display – otherwise the machine could theoretically fall
            //    asleep between the two steps.
            guard powerManager.start() else {
                presentAssertionFailureAlert()
                updateUI(active: false)
                return
            }
            // 2. Turn off the display immediately instead of waiting for
            //    the configured display-sleep timer.
            do {
                try DisplayController.sleepNow()
            } catch {
                presentDisplaySleepFailureAlert(error)
                // Sleep protection stays active regardless.
            }
        } else {
            powerManager.stop()
        }
        updateUI(active: active)
    }

    private func updateUI(active: Bool) {
        statusItem.button?.image = statusImage(active: active)
        toggleItem.state = active ? .on : .off
        statusLabelItem.title = active
            ? "Active – Display off, system awake"
            : "Inactive"
    }

    private func statusImage(active: Bool) -> NSImage? {
        let symbolName = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let description = active ? "Sleep protection active" : "Sleep protection inactive"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        return image
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
