import CoreGraphics
import Foundation

/// Controls display brightness via the private DisplayServices framework
/// – the same undocumented API used by tools like `brightness`
/// (nriley/M1 forks) and Apple's own Control Center. There is no public
/// API for this; Apple has never shipped one.
///
/// Despite the framework's name this isn't limited to the built-in
/// panel: displays with their own Apple silicon – the Studio Display and
/// Pro Display XDR – register brightness through this same native
/// mechanism rather than DDC/CI, because they're not "dumb" monitors.
/// Only genuinely third-party displays need `ExternalDisplayBrightness`'s
/// DDC/CI fallback. Callers should try this first for every display and
/// only fall back to DDC for the ones it doesn't support.
///
/// Loaded via `dlopen`/`dlsym` rather than linked at build time, so a
/// missing or renamed symbol on some future macOS version just disables
/// this feature instead of preventing the app from launching at all.
enum NativeDisplayBrightness {

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

    /// Current brightness in 0.0...1.0, or `nil` if this display doesn't
    /// support the native path (e.g. a third-party DDC-only monitor) or
    /// the API is unavailable.
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
