import CoreGraphics
import Foundation

/// Polls system-wide idle time to detect keyboard *or* mouse activity
/// while "Dim Display" is active, so it can auto-restore the same way
/// "Turn Display Off" already does via `screensDidWakeNotification`.
///
/// A plain `NSEvent` global monitor could catch mouse activity without any
/// extra permission, but not keyboard activity: Apple's own documentation
/// for `NSEvent.addGlobalMonitorForEvents` states that key-related global
/// events are only delivered to a trusted Accessibility client – exactly
/// the kind of permission this app otherwise avoids needing anywhere (see
/// `HotKeyManager`). Polling `CGEventSource.secondsSinceLastEventType`
/// (the Swift overlay for `CGEventSourceSecondsSinceLastEventType`) with
/// `kCGAnyInputEventType` sidesteps that entirely: it's the same public,
/// permission-free mechanism macOS itself uses for idle-sleep/screensaver
/// timing, and reports elapsed time since the last event of *any* kind –
/// keyboard included.
final class IdleActivityMonitor {

    /// `kCGAnyInputEventType` from `CGEventTypes.h` – `#define
    /// kCGAnyInputEventType ((CGEventType)(~0))`. Not exposed as a Swift
    /// constant since it's a C macro rather than a typed enum case, and
    /// `CGEventType(rawValue:)` is failable and refuses unrecognized raw
    /// values (nil for `~0`), so this reconstructs it with a raw bit-cast
    /// instead – safe here since the value is only ever handed opaquely to
    /// the C API below, never switched over in Swift.
    private static let anyInputEventType = unsafeBitCast(UInt32.max, to: CGEventType.self)

    /// How often to poll. Frequent enough that restoring feels immediate,
    /// cheap enough not to matter for a timer that only runs while
    /// actually dimmed.
    private static let pollInterval: TimeInterval = 0.3

    private var timer: Timer?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// No-op if already running.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        if idleSeconds < Self.pollInterval {
            handler()
        }
    }

    deinit {
        stop()
    }
}
