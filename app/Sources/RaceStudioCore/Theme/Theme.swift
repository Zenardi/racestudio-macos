import Foundation

/// A named, semantic color role in the brand palette (issue 7.3). Views ask for a
/// *role* — never a raw hue — so the identity stays in one place and the WCAG
/// proof can iterate every role exhaustively (`allCases`).
public enum ColorRole: String, CaseIterable, Sendable {
    case background
    case surface
    case surfaceElevated
    case textPrimary
    case textSecondary
    case accent
    case onAccent
    case separator
    case positive
    case negative
}

/// How a ``ColorRole`` participates in contrast: a `text` role must clear WCAG AA
/// (≥ 4.5:1) on every `surface`; `accent`/`onAccent` are proven as a pair; a
/// `decorative` role (hairlines) carries no text-contrast obligation. Classifying
/// every role here through one exhaustive `switch` forces a newly added role to be
/// categorized — and, if it is text, contrast-checked — before it can compile.
public enum ColorRoleKind: Sendable {
    case surface
    case text
    case accent
    case onAccent
    case decorative
}

extension ColorRole {
    /// The contrast category this role belongs to (see ``ColorRoleKind``). The
    /// accessibility proof in `ThemeTests` derives its foreground/surface sets from
    /// this, so classification and verification can never drift apart.
    public var kind: ColorRoleKind {
        switch self {
        case .background, .surface, .surfaceElevated: return .surface
        case .textPrimary, .textSecondary, .positive, .negative: return .text
        case .accent: return .accent
        case .onAccent: return .onAccent
        case .separator: return .decorative
        }
    }
}

/// The semantic color palette: one ``ThemeColor`` (light + dark) per role.
///
/// The initializer does not itself enforce contrast; rather, the shipped
/// ``Theme/raceStudio`` palette is *proven* by `ThemeTests` to clear WCAG AA —
/// every text role (`textPrimary`, `textSecondary`, `positive`, `negative`)
/// ≥ 4.5:1 against every surface in both appearances, and `onAccent` ≥ 4.5:1 on
/// `accent`. A hand-built palette carries no such guarantee until it is likewise
/// tested.
public struct Palette: Hashable, Sendable {
    public let background: ThemeColor
    public let surface: ThemeColor
    public let surfaceElevated: ThemeColor
    public let textPrimary: ThemeColor
    public let textSecondary: ThemeColor
    public let accent: ThemeColor
    public let onAccent: ThemeColor
    public let separator: ThemeColor
    public let positive: ThemeColor
    public let negative: ThemeColor

    public init(background: ThemeColor, surface: ThemeColor, surfaceElevated: ThemeColor,
                textPrimary: ThemeColor, textSecondary: ThemeColor,
                accent: ThemeColor, onAccent: ThemeColor, separator: ThemeColor,
                positive: ThemeColor, negative: ThemeColor) {
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = accent
        self.onAccent = onAccent
        self.separator = separator
        self.positive = positive
        self.negative = negative
    }

    /// The ``ThemeColor`` for a semantic `role`.
    public func color(_ role: ColorRole) -> ThemeColor {
        switch role {
        case .background: return background
        case .surface: return surface
        case .surfaceElevated: return surfaceElevated
        case .textPrimary: return textPrimary
        case .textSecondary: return textSecondary
        case .accent: return accent
        case .onAccent: return onAccent
        case .separator: return separator
        case .positive: return positive
        case .negative: return negative
        }
    }
}

/// The weight axis of a ``FontToken`` — kept as a value so the tested core never
/// imports SwiftUI; the shell maps it to `Font.Weight`.
public enum FontWeight: String, CaseIterable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

/// The Dynamic Type anchor a ``FontToken`` scales against. The shell renders each
/// token through the matching SwiftUI text style, so type responds to the system
/// accessibility text-size setting rather than being pinned to a fixed point
/// size; ``FontToken/size`` is the reference size at the default setting.
public enum TextStyleAnchor: String, CaseIterable, Sendable {
    case largeTitle
    case title
    case headline
    case body
    case callout
    case caption
}

/// One type-scale step: a Dynamic Type anchor, a reference point size, a weight,
/// and whether digits are monospaced (telemetry readouts must not jitter as
/// values change).
public struct FontToken: Hashable, Sendable {
    public let size: Double
    public let weight: FontWeight
    public let textStyle: TextStyleAnchor
    public let monospacedDigit: Bool

    public init(size: Double, weight: FontWeight = .regular,
                textStyle: TextStyleAnchor, monospacedDigit: Bool = false) {
        self.size = size
        self.weight = weight
        self.textStyle = textStyle
        self.monospacedDigit = monospacedDigit
    }
}

/// The typographic scale — named steps from `largeTitle` down to `caption`, plus
/// a `readout` step for monospaced telemetry numbers.
public struct TypeScale: Hashable, Sendable {
    public let largeTitle: FontToken
    public let title: FontToken
    public let headline: FontToken
    public let body: FontToken
    public let callout: FontToken
    public let caption: FontToken
    public let readout: FontToken

    public init(largeTitle: FontToken, title: FontToken, headline: FontToken, body: FontToken,
                callout: FontToken, caption: FontToken, readout: FontToken) {
        self.largeTitle = largeTitle
        self.title = title
        self.headline = headline
        self.body = body
        self.callout = callout
        self.caption = caption
        self.readout = readout
    }
}

/// The spacing scale — a strictly increasing 4-point grid consumed for padding
/// and stack spacing so layout rhythm is consistent everywhere.
public struct SpacingScale: Hashable, Sendable {
    public let xs: Double
    public let sm: Double
    public let md: Double
    public let lg: Double
    public let xl: Double
    public let xxl: Double

    public init(xs: Double, sm: Double, md: Double, lg: Double, xl: Double, xxl: Double) {
        self.xs = xs
        self.sm = sm
        self.md = md
        self.lg = lg
        self.xl = xl
        self.xxl = xxl
    }
}

/// The corner-rounding scale for cards, thumbnails, and controls.
public struct RadiusScale: Hashable, Sendable {
    public let sm: Double
    public let md: Double
    public let lg: Double

    public init(sm: Double, md: Double, lg: Double) {
        self.sm = sm
        self.md = md
        self.lg = lg
    }
}

/// The RaceStudio brand design-token set (issue 7.3, #141): palette, type scale,
/// spacing, and rounding, resolved per light/dark ``Appearance``.
///
/// This is the single source of truth for the app's visual identity. Views read
/// tokens through the SwiftUI-shell environment (`\.theme`) and never hard-code a
/// hue, size, or gap. See `docs/BRAND.md` for the rationale and contrast table.
public struct Theme: Hashable, Sendable {
    public let palette: Palette
    public let typography: TypeScale
    public let spacing: SpacingScale
    public let radius: RadiusScale

    public init(palette: Palette, typography: TypeScale, spacing: SpacingScale, radius: RadiusScale) {
        self.palette = palette
        self.typography = typography
        self.spacing = spacing
        self.radius = radius
    }

    /// The standard RaceStudio identity: a motorsport-red accent on a cool
    /// near-neutral canvas, tuned so every text/surface pair clears WCAG AA in
    /// both appearances (proven in `ThemeTests`).
    public static let raceStudio = Theme(
        palette: Palette(
            background: ThemeColor(light: .rgb(241, 243, 245), dark: .rgb(14, 17, 22)),
            surface: ThemeColor(light: .rgb(250, 251, 252), dark: .rgb(25, 30, 38)),
            surfaceElevated: ThemeColor(light: .rgb(255, 255, 255), dark: .rgb(34, 40, 51)),
            textPrimary: ThemeColor(light: .rgb(20, 23, 28), dark: .rgb(242, 244, 247)),
            textSecondary: ThemeColor(light: .rgb(86, 92, 102), dark: .rgb(167, 175, 186)),
            accent: ThemeColor(light: .rgb(194, 26, 43), dark: .rgb(220, 42, 59)),
            onAccent: ThemeColor(.rgb(255, 255, 255)),
            separator: ThemeColor(light: .rgb(216, 220, 226), dark: .rgb(51, 59, 71)),
            positive: ThemeColor(light: .rgb(19, 122, 56), dark: .rgb(63, 185, 100)),
            negative: ThemeColor(light: .rgb(194, 26, 43), dark: .rgb(255, 107, 119))),
        typography: TypeScale(
            largeTitle: FontToken(size: 26, weight: .bold, textStyle: .largeTitle),
            title: FontToken(size: 20, weight: .semibold, textStyle: .title),
            headline: FontToken(size: 15, weight: .semibold, textStyle: .headline),
            body: FontToken(size: 13, weight: .regular, textStyle: .body),
            callout: FontToken(size: 12, weight: .regular, textStyle: .callout),
            caption: FontToken(size: 11, weight: .regular, textStyle: .caption),
            readout: FontToken(size: 13, weight: .medium, textStyle: .body, monospacedDigit: true)),
        spacing: SpacingScale(xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32),
        radius: RadiusScale(sm: 4, md: 8, lg: 12))
}
