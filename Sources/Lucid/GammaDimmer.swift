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

    /// Fraction of the normal output range each channel is capped to.
    /// Not quite 0 so a dimmed display still reads as "on, very dark"
    /// rather than looking indistinguishable from "off"/blanked.
    private static let outputCeiling: CGGammaValue = 0.01

    /// Caps `display`'s gamma output near black. Safe to call on any
    /// active display, including ones `NativeDisplayBrightness`/
    /// `ExternalDisplayBrightness` don't support – this doesn't depend on
    /// either.
    static func dim(_ display: CGDirectDisplayID) {
        CGSetDisplayTransferByFormula(
            display,
            0, outputCeiling, 1,
            0, outputCeiling, 1,
            0, outputCeiling, 1
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
