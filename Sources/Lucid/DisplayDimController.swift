import CoreGraphics
import Foundation

/// Alternative to `DisplayController.sleepNow()`: dims all displays to
/// (near-)minimum brightness instead of putting them to sleep, while
/// keeping them logically "on". This avoids the reduced CPU performance
/// state macOS/the SoC seems to apply when no display is actively
/// signaling – see the README for background. Trade-off: only the
/// built-in display is dimmed reliably; external displays depend on
/// DDC/CI support, which varies by monitor/cable/hub and hasn't been
/// verified against real hardware (see ExternalDisplayBrightness.swift).
final class DisplayDimController {

    private(set) var isDimmed = false

    private var savedBuiltInBrightness: [CGDirectDisplayID: Float] = [:]
    private var savedExternalBrightness: [(service: AnyObject, value: UInt16)] = []

    /// Dims every active display. Always "succeeds" in the sense that it
    /// never throws – displays that can't be controlled (API unsupported,
    /// DDC failed, ...) are silently left alone.
    func dim() {
        guard !isDimmed else { return }
        isDimmed = true

        for display in activeDisplayIDs() where CGDisplayIsBuiltin(display) != 0 {
            if let current = BuiltInDisplayBrightness.brightness(of: display) {
                savedBuiltInBrightness[display] = current
                BuiltInDisplayBrightness.setBrightness(0.0, of: display)
            }
        }

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

        for (display, value) in savedBuiltInBrightness {
            BuiltInDisplayBrightness.setBrightness(value, of: display)
        }
        savedBuiltInBrightness.removeAll()

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
