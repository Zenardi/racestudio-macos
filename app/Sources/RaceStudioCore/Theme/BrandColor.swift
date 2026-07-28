import Foundation

/// A render-agnostic sRGB color that carries its own WCAG contrast math (issue
/// 7.3, #141).
///
/// Like ``PlotColor`` for plotted traces, this is kept independent of SwiftUI so
/// the brand palette can be *defined and proven* in the tested core — every
/// text-on-surface pair is asserted against ``contrastRatio(against:)`` — and the
/// thin `@main` shell merely maps it to a `SwiftUI.Color`. Components are stored
/// in `0...1`; the ``rgb(_:_:_:alpha:)`` factory authors from `0...255` bytes.
public struct BrandColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Builds a color from unit components. Each is clamped to `0...1`, so a
    /// stray value can never produce an out-of-gamut (or `NaN`-propagating) color.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        // `min`/`max` clamp ±∞ correctly but *propagate* NaN (every comparison is
        // false), so NaN is mapped to 0 explicitly — the type never carries a NaN.
        func unit(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        self.red = unit(red)
        self.green = unit(green)
        self.blue = unit(blue)
        self.alpha = unit(alpha)
    }

    /// Authors a color from `0...255` sRGB bytes — how the palette is written.
    /// Bytes are clamped into range, so `rgb(300, -5, 0)` is opaque pure red.
    public static func rgb(_ red: Int, _ green: Int, _ blue: Int, alpha: Double = 1) -> BrandColor {
        func byte(_ value: Int) -> Double { Double(min(max(value, 0), 255)) / 255 }
        return BrandColor(red: byte(red), green: byte(green), blue: byte(blue), alpha: alpha)
    }

    /// Parses a `#RRGGBB` / `RRGGBB` hex string (case-insensitive). Returns `nil`
    /// for any malformed input rather than guessing — a convenience for consumers;
    /// the palette itself is authored through ``rgb(_:_:_:alpha:)``.
    public init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self = BrandColor.rgb(Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// The WCAG 2.1 relative luminance of the color (0 = black, 1 = white),
    /// computed from the linearized sRGB components. Alpha is ignored: contrast is
    /// only meaningful for the opaque text/surface tokens that use it.
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between this color and `other`, in `1...21`. The
    /// ratio is symmetric — the lighter luminance is always the numerator — so
    /// argument order does not matter.
    public func contrastRatio(against other: BrandColor) -> Double {
        let lhs = relativeLuminance
        let rhs = other.relativeLuminance
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}
