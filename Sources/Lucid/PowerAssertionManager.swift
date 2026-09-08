import Foundation
import IOKit.pwr_mgt

/// Prevents macOS from going into system sleep (standby) due to
/// inactivity, without affecting the screensaver/display-sleep timer.
/// This is equivalent to `caffeinate -i` or Amphetamine's "allow display
/// to sleep" mode: the machine stays awake, the display still turns off
/// after the time configured in System Settings, and is turned back on by
/// keyboard or mouse activity exactly as macOS normally does.
final class PowerAssertionManager {

    private(set) var isActive: Bool = false
    private var assertionID: IOPMAssertionID = 0

    /// Activates the power assertion. Returns `false` if the system
    /// rejects the request (e.g. due to missing permissions).
    @discardableResult
    func start(reason: String = "Prevents sleep, display is allowed to turn off") -> Bool {
        guard !isActive else { return true }

        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )

        guard result == kIOReturnSuccess else { return false }

        assertionID = newID
        isActive = true
        return true
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }
}
