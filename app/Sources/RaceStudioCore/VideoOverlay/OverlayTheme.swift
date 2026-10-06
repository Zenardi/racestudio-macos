import Foundation

/// How a widget's background plate is drawn (issue 9.10).
public enum OverlayPlateStyle: String, Codable, CaseIterable, Sendable {
    /// No plate: the readout sits straight on the footage (the renderer strokes
    /// its text for legibility, but no contrast is guaranteed).
    case none
    /// A dark plate that lets the footage through
    /// (``OverlayTheme/translucentPlateOpacity``).
    case translucent
    /// An opaque dark plate.
    case solid
}

/// The video overlay's colours (issue 9.10): the plate, the text, the accent the
/// RPM bar and map dot are drawn in, the delta's gain green and loss red, and the
/// shift light's warning — shared by the live HUD and the export.
///
/// The colours are the brand's ``Theme`` tokens in their **dark** appearance (a
/// HUD over footage is always "dark mode"). Only ``warning`` is the overlay's
/// own: the brand palette has no warning role, and the shift light needs a hue
/// apart from both the accent-red bar and the gain/loss pair.
///
/// ``raceStudio`` is *proven* by `OverlayThemeContrastTests` to keep every
/// ``TextRole`` at WCAG AA (≥ 4.5:1) on a solid plate, and on the translucent
/// plate over pure white or black footage, at full widget opacity. A theme
/// persists by its ``id`` only, so a saved layout always draws in today's tokens.
public struct OverlayTheme: Equatable, Sendable {

    /// The colours text is drawn in — each one contrast-checked on the plate.
    public enum TextRole: CaseIterable, Sendable {
        /// Readouts: speed, lap times, gear.
        case primary
        /// Labels and units.
        case secondary
        /// A negative delta — gaining time.
        case gain
        /// A positive delta — losing time.
        case loss
        /// The shift light's call-out.
        case warning
    }

    /// The name the theme persists under.
    public let id: String
    /// The plate's colour (opaque).
    public let plate: BrandColor
    /// How much of the plate covers the footage when it is
    /// ``OverlayPlateStyle/translucent``.
    public let translucentPlateOpacity: Double
    /// Readout text.
    public let text: BrandColor
    /// Labels and units.
    public let secondaryText: BrandColor
    /// The RPM bar, the map's position dot.
    public let accent: BrandColor
    /// Gaining time (delta < 0).
    public let gain: BrandColor
    /// Losing time (delta > 0).
    public let loss: BrandColor
    /// The shift light.
    public let warning: BrandColor

    /// The overlay theme drawn from `brand`'s dark-appearance tokens.
    public init(id: String, brand: Theme, translucentPlateOpacity: Double = 0.88,
                warning: BrandColor = .rgb(255, 184, 0)) {
        let palette = brand.palette
        self.id = id
        self.plate = palette.background.dark
        self.translucentPlateOpacity = translucentPlateOpacity
        self.text = palette.textPrimary.dark
        self.secondaryText = palette.textSecondary.dark
        self.accent = palette.accent.dark
        self.gain = palette.positive.dark
        self.loss = palette.negative.dark
        self.warning = warning
    }

    /// The RaceStudio HUD.
    public static let raceStudio = OverlayTheme(id: "raceStudio", brand: .raceStudio)

    /// Every theme this build draws — what a persisted ``id`` resolves against.
    public static let builtIn: [OverlayTheme] = [.raceStudio]

    /// The colour of a text `role`.
    public func color(_ role: TextRole) -> BrandColor {
        switch role {
        case .primary: return text
        case .secondary: return secondaryText
        case .gain: return gain
        case .loss: return loss
        case .warning: return warning
        }
    }

    /// The plate's fill for `style`, with its opacity as alpha; `nil` for no plate.
    public func plateFill(_ style: OverlayPlateStyle) -> BrandColor? {
        switch style {
        case .none: return nil
        case .translucent: return plate.withAlpha(translucentPlateOpacity)
        case .solid: return plate.withAlpha(1)
        }
    }

    /// The opaque colour the plate for `style` shows over `backdrop` footage
    /// (source-over, in sRGB like the renderer's bitmap) — what text is read
    /// against; `nil` for no plate.
    public func effectivePlate(_ style: OverlayPlateStyle, over backdrop: BrandColor) -> BrandColor? {
        guard let fill = plateFill(style) else { return nil }
        func blend(_ top: Double, _ bottom: Double) -> Double { top * fill.alpha + bottom * (1 - fill.alpha) }
        return BrandColor(red: blend(fill.red, backdrop.red), green: blend(fill.green, backdrop.green),
                          blue: blend(fill.blue, backdrop.blue))
    }
}

extension OverlayTheme: Codable {

    /// Decodes a persisted ``id``; one this build doesn't know reads as
    /// ``raceStudio`` rather than failing the layout (and counts as unread, see
    /// `SkippedElementCounter`).
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let known = Self.builtIn.first(where: { $0.id == id }) else {
            SkippedElementCounter.record(in: decoder)
            self = .raceStudio
            return
        }
        self = known
    }

    /// Encodes the ``id`` alone.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

extension BrandColor {
    /// The same colour at `alpha`.
    func withAlpha(_ alpha: Double) -> BrandColor {
        BrandColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
