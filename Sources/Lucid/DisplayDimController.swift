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
final class DisplayDimController {

    private(set) var isDimmed = false

    private var savedNativeBrightness: [CGDirectDisplayID: Float] = [:]
    private var savedExternalBrightness: [(service: AnyObject, value: UInt16)] = []

    /// Dims every active display. Always "succeeds" in the sense that it
    /// never throws – displays that can't be controlled (API unsupported,
    /// DDC failed, ...) are silently left alone.
    func dim() {
        guard !isDimmed else { return }
        isDimmed = true

        let displays = activeDisplayIDs()
        for display in displays {
            if let current = NativeDisplayBrightness.brightness(of: display) {
                savedNativeBrightness[display] = current
                NativeDisplayBrightness.setBrightness(0.0, of: display)
            }
        }

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

        for (display, value) in savedNativeBrightness {
            NativeDisplayBrightness.setBrightness(value, of: display)
        }
        savedNativeBrightness.removeAll()

        for (service, value) in savedExternalBrightness {
            ExternalDisplayBrightness.setBrightness(value, of: service)
        }
        savedExternalBrightness.removeAll()
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return [] }
        return displays
    }
}
