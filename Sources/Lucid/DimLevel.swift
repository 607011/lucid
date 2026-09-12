import CoreGraphics

/// Range and default for how dark "Dim Display"/"Show Activity Monitor"
/// make every display – continuous (a slider in the menu, see
/// `AppDelegate.dimLevelSliderItem`) rather than a few fixed presets, so
/// the user can dial in exactly how much residual glow/brightness they
/// want instead of picking the nearest of three fixed points.
///
/// The same 0...1 value doubles as two different things depending on the
/// mode (see `DimStyle`): a gamma ceiling for "Dim Display" (an LCD
/// blocks its backlight per pixel, so even a fairly low gamma ceiling
/// already looks pitch black in practice – confirmed on a Studio
/// Display, where anything past ~0.2 stopped reading as "dim" at all and
/// started looking like a lit screen), and a hardware brightness fraction
/// for "Show Activity Monitor" (where the chart needs to stay legible,
/// not get capped toward black).
enum DimLevel {
    static let minCeiling: CGGammaValue = 0.0
    static let maxCeiling: CGGammaValue = 0.3
    static let defaultCeiling: CGGammaValue = GammaDimmer.defaultCeiling
}
