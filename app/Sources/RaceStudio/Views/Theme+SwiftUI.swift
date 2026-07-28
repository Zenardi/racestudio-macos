import SwiftUI
import RaceStudioCore

/// The thin SwiftUI bridge for the brand design tokens (issue 7.3, #141).
///
/// Every visual rule — the palette, the WCAG-proven contrast, the type/spacing/
/// rounding scales — lives in `RaceStudioCore`'s ``Theme``. This file only maps
/// those value tokens onto SwiftUI (`Color`, `Font`) and threads the active
/// ``Theme`` through the environment, so views stay declarative and the `@main`
/// shell carries no styling logic.
extension Color {
    /// Bridges a render-agnostic ``BrandColor`` to a SwiftUI `Color`.
    init(_ brandColor: BrandColor) {
        self.init(.sRGB,
                  red: brandColor.red,
                  green: brandColor.green,
                  blue: brandColor.blue,
                  opacity: brandColor.alpha)
    }
}

extension ColorScheme {
    /// The core ``Appearance`` for this SwiftUI scheme (anything not dark is light).
    var appearance: Appearance { self == .dark ? .dark : .light }
}

extension ThemeColor {
    /// The SwiftUI `Color` for the current `scheme` — the one call sites use to
    /// paint a semantic role without touching the light/dark split themselves.
    func color(_ scheme: ColorScheme) -> Color { Color(resolve(scheme.appearance)) }
}

extension Font.Weight {
    /// Maps a core ``FontWeight`` token onto a SwiftUI weight.
    init(_ weight: FontWeight) {
        switch weight {
        case .regular: self = .regular
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        }
    }
}

extension Font.TextStyle {
    /// Maps a core ``TextStyleAnchor`` onto a SwiftUI Dynamic Type text style.
    init(_ anchor: TextStyleAnchor) {
        switch anchor {
        case .largeTitle: self = .largeTitle
        case .title: self = .title
        case .headline: self = .headline
        case .body: self = .body
        case .callout: self = .callout
        case .caption: self = .caption
        }
    }
}

extension Font {
    /// Builds a SwiftUI `Font` from a ``FontToken``: rendered through the token's
    /// Dynamic Type anchor so it scales with the system text-size setting, carrying
    /// the token's weight and (for telemetry readouts) monospaced digits.
    static func token(_ token: FontToken) -> Font {
        let base = Font.system(Font.TextStyle(token.textStyle)).weight(Font.Weight(token.weight))
        return token.monospacedDigit ? base.monospacedDigit() : base
    }
}

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .raceStudio
}

extension EnvironmentValues {
    /// The active brand ``Theme``. Defaults to ``Theme/raceStudio`` so any view can
    /// read tokens even if a parent forgot to inject one.
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
