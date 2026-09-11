import CoreGraphics

/// Extra dimming layered on top of `NativeDisplayBrightness` /
/// `ExternalDisplayBrightness`, applied via each display's gamma table
/// instead of its backlight.
///
/// The built-in panel's hardware brightness floor is close enough to true
/// black that zeroing it out (via `NativeDisplayBrightness`) alone looks
/// convincingly dark. The Studio Display's floor sits noticeably higher –
/// at brightness 0 it still shows a clearly visible glow, well short of
/// the built-in panel. Since there's no lower hardware brightness to ask
/// for, the only way to close that gap is to stop relying on the backlight
/// for the last stretch and instead scale down what's actually being
/// rendered: `CGSetDisplayTransferByFormula` remaps every pixel's output
/// through a per-channel gamma curve, so capping that curve's max near
/// zero makes the whole display render close to black independent of its
/// backlight/hardware minimum. Public (if long-deprecated) Quartz Display
/// Services API – the same mechanism f.lux-style tools use – so unlike
/// `NativeDisplayBrightness`/`ExternalDisplayBrightness` this needs no
/// `dlopen`.
enum GammaDimmer {

    /// Default fraction of the normal output range each channel is capped
    /// to, used unless the user picked a different `DimLevel`. Not quite 0
    /// so a dimmed display still reads as "on, very dark" rather than
    /// looking indistinguishable from "off"/blanked.
    static let defaultCeiling: CGGammaValue = 0.01

    /// Caps `display`'s gamma output near black. Safe to call on any
    /// active display, including ones `NativeDisplayBrightness`/
    /// `ExternalDisplayBrightness` don't support – this doesn't depend on
    /// either. Also safe to call repeatedly/idempotently on an
    /// already-dimmed display, which `DisplayDimController` relies on when
    /// a new display is hot-plugged while already dimmed.
    static func dim(_ display: CGDirectDisplayID, ceiling: CGGammaValue = defaultCeiling) {
        CGSetDisplayTransferByFormula(
            display,
            0, ceiling, 1,
            0, ceiling, 1,
            0, ceiling, 1
        )
    }

    /// Restores every display's gamma table to its normal, ColorSync-
    /// managed curve. There's no per-display counterpart to this call –
    /// it's system-wide – but `DisplayDimController` only ever dims "all
    /// displays" as a group, so that's not a real limitation here. Note
    /// this also resets gamma adjustments made by anything else running at
    /// the time (Night Shift's manual slider, f.lux, ...).
    static func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
