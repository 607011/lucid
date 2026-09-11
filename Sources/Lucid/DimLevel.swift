import CoreGraphics

/// User-selectable presets for how dark "Dim Display" makes every display,
/// via the gamma ceiling passed to `GammaDimmer`/`DisplayDimController`.
/// Persisted the same way as `SleepPreventionMode` (see `AppDelegate`).
enum DimLevel: Int, CaseIterable {
    /// The default: matches `GammaDimmer.defaultCeiling`, dark enough that
    /// a Studio Display matches a MacBook's built-in panel. Deliberately
    /// `rawValue == 0`, the same as `UserDefaults.integer(forKey:)`'s
    /// fallback for a key that was never set – see `AppDelegate.dimLevel`
    /// (mirrors `SleepPreventionMode.turnOffDisplay` doing the same for
    /// `mode`).
    case veryDark
    /// Gamma output clamped all the way to 0 – true black, rendering no
    /// distinction between "on, dimmed" and "off" left to the eye.
    case pitchBlack
    /// A deliberately visible residual glow – e.g. as a faint nightlight
    /// instead of a pitch-black room.
    case faintGlow

    var gammaCeiling: CGGammaValue {
        switch self {
        case .pitchBlack: return 0.0
        case .veryDark: return GammaDimmer.defaultCeiling
        case .faintGlow: return 0.05
        }
    }

    var title: String {
        switch self {
        case .pitchBlack: return "Pitch Black"
        case .veryDark: return "Very Dark (Default)"
        case .faintGlow: return "Faint Glow"
        }
    }

    /// Darkest-to-brightest order for building the "Dim Level" menu –
    /// independent of declaration/`rawValue` order above, which is fixed
    /// for `UserDefaults` compatibility instead of readability.
    static let displayOrder: [DimLevel] = [.pitchBlack, .veryDark, .faintGlow]
}
