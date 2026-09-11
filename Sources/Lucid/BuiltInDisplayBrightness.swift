import CoreGraphics
import Foundation

/// Controls the brightness of the built-in display via the private
/// DisplayServices framework – the same undocumented API used by tools
/// like `brightness` (nriley/M1 forks) and Apple's own Control Center.
/// There is no public API for this; Apple has never shipped one.
///
/// Loaded via `dlopen`/`dlsym` rather than linked at build time, so a
/// missing or renamed symbol on some future macOS version just disables
/// this feature instead of preventing the app from launching at all.
enum BuiltInDisplayBrightness {

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static let getBrightness: GetBrightnessFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    private static let setBrightness: SetBrightnessFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFn.self)
    }()

    /// Whether this API is available at all on the current system.
    static var isSupported: Bool {
        getBrightness != nil && setBrightness != nil
    }

    /// Current brightness in 0.0...1.0, or `nil` if unavailable/failed.
    static func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        let status = getBrightness(display, &value)
        return status == 0 ? value : nil
    }

    /// Returns `true` on success.
    @discardableResult
    static func setBrightness(_ value: Float, of display: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(display, max(0, min(1, value))) == 0
    }
}
