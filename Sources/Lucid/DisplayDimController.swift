import CoreGraphics
import Foundation

/// Alternative to `DisplayController.sleepNow()`: dims all displays to
/// (near-)minimum brightness instead of putting them to sleep, while
/// keeping them logically "on". This avoids the reduced CPU performance
/// state macOS/the SoC seems to apply when no display is actively
/// signaling – see the README for background.
///
/// Every display is tried via the reliable native path first
/// (`NativeDisplayBrightness` – covers the built-in panel, Studio
/// Display, and Pro Display XDR). Only if at least one display doesn't
/// support that is the unverified DDC/CI fallback
/// (`ExternalDisplayBrightness`) attempted at all, for whichever
/// third-party monitors are left – so a Mac with only "native" displays
/// attached never touches the DDC path.
///
/// On top of whatever hardware brightness it manages to set, every
/// display also gets its gamma output capped near-black via
/// `GammaDimmer`. Hardware brightness alone leaves some displays (the
/// Studio Display in particular) visibly brighter at their minimum than
/// e.g. a MacBook's built-in panel – the gamma cap closes that gap
/// regardless of where each display's hardware floor happens to sit.
///
/// While dimmed, a `CGDisplayRegisterReconfigurationCallback` watches for
/// newly connected displays (e.g. plugging in a second monitor mid-dim)
/// and dims those too – both native brightness and the gamma cap, so a
/// hot-plugged display doesn't stay at full brightness until the next
/// dim/restore cycle. Hot-plugged DDC-only external displays only get the
/// gamma cap, not the DDC/CI brightness reduction – matching a new
/// service back to a specific `CGDirectDisplayID` on the fly isn't
/// something `ExternalDisplayBrightness` supports (see there); the gamma
/// cap alone still gets them visually dark.
final class DisplayDimController {

    private(set) var isDimmed = false

    private var savedNativeBrightness: [CGDirectDisplayID: Float] = [:]
    private var savedExternalBrightness: [(service: AnyObject, value: UInt16)] = []
    private var gammaCeiling: CGGammaValue = GammaDimmer.defaultCeiling
    private var isObservingReconfiguration = false

    /// Dims every active display. Always "succeeds" in the sense that it
    /// never throws – displays that can't be controlled (API unsupported,
    /// DDC failed, ...) are silently left alone.
    func dim(gammaCeiling: CGGammaValue = GammaDimmer.defaultCeiling) {
        guard !isDimmed else { return }
        isDimmed = true
        self.gammaCeiling = gammaCeiling

        let displays = activeDisplayIDs()
        for display in displays {
            dimNatively(display)
        }
        startObservingReconfiguration()

        // DDC is the unreliable, unverified fallback – skip it entirely
        // if the native path already handled every display (e.g. a
        // MacBook, or a MacBook plus a Studio Display).
        guard savedNativeBrightness.count < displays.count else { return }

        for service in ExternalDisplayBrightness.allExternalServices() {
            if let current = ExternalDisplayBrightness.brightness(of: service) {
                savedExternalBrightness.append((service, current))
                ExternalDisplayBrightness.setBrightness(0, of: service)
            }
        }
    }

    /// Restores every display this instance actually dimmed to its
    /// previous brightness.
    func restore() {
        guard isDimmed else { return }
        isDimmed = false

        stopObservingReconfiguration()
        GammaDimmer.restoreAll()

        for (display, value) in savedNativeBrightness {
            NativeDisplayBrightness.setBrightness(value, of: display)
        }
        savedNativeBrightness.removeAll()

        for (service, value) in savedExternalBrightness {
            ExternalDisplayBrightness.setBrightness(value, of: service)
        }
        savedExternalBrightness.removeAll()
    }

    /// Applies both the native-brightness-zeroing and the gamma cap to one
    /// display. Idempotent: safe to call again on a display that's
    /// already dimmed (used both for the initial pass and for displays
    /// that appear later via hot-plug), since it only *saves* a display's
    /// brightness the first time it sees it.
    private func dimNatively(_ display: CGDirectDisplayID) {
        if savedNativeBrightness[display] == nil, let current = NativeDisplayBrightness.brightness(of: display) {
            savedNativeBrightness[display] = current
            NativeDisplayBrightness.setBrightness(0.0, of: display)
        }
        GammaDimmer.dim(display, ceiling: gammaCeiling)
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return [] }
        return displays
    }

    // MARK: - Hot-plug handling

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard flags.contains(.addFlag), let userInfo else { return }
        let controller = Unmanaged<DisplayDimController>.fromOpaque(userInfo).takeUnretainedValue()
        controller.dimNewlyConnectedDisplays()
    }

    private func startObservingReconfiguration() {
        guard !isObservingReconfiguration else { return }
        isObservingReconfiguration = true
        CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func stopObservingReconfiguration() {
        guard isObservingReconfiguration else { return }
        isObservingReconfiguration = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Called (on the main thread, per Quartz's contract for this
    /// callback) whenever a display is added while dimmed. Re-dims every
    /// currently active display rather than just the new one – harmless
    /// for ones already dimmed since `dimNatively` is idempotent, and
    /// simpler than trying to identify exactly which display ID(s) the
    /// callback's flags refer to.
    private func dimNewlyConnectedDisplays() {
        guard isDimmed else { return }
        for display in activeDisplayIDs() {
            dimNatively(display)
        }
    }
}
