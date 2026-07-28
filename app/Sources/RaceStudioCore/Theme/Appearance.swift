/// The macOS light/dark appearance a ``ThemeColor`` resolves against (issue 7.3).
///
/// The thin shell maps SwiftUI's `ColorScheme` onto this so the tested core never
/// needs to import SwiftUI to reason about light vs dark.
public enum Appearance: String, CaseIterable, Sendable {
    case light
    case dark
}

/// A single brand color with its light and dark values (issue 7.3). Every palette
/// role is one of these, so switching appearance is a pure lookup — and the
/// accessibility proof can assert both variants without a running app.
public struct ThemeColor: Hashable, Sendable {
    public let light: BrandColor
    public let dark: BrandColor

    public init(light: BrandColor, dark: BrandColor) {
        self.light = light
        self.dark = dark
    }

    /// A color that is identical in both appearances (e.g. text on the accent).
    public init(_ both: BrandColor) {
        self.light = both
        self.dark = both
    }

    /// The concrete ``BrandColor`` for `appearance`.
    public func resolve(_ appearance: Appearance) -> BrandColor {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }
}
