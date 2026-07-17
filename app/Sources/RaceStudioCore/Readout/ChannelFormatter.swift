import Foundation

/// Formats a channel value with its unit suffix and decimal precision
/// (issue 4.4), rendering absent / non-finite values as an em dash rather than
/// "nan". Reuses ``ChannelFormatting/emDash`` so the placeholder is consistent
/// with the rest of the app.
public struct ChannelFormatter: Sendable {
    /// The unit suffix (e.g. `"km/h"`); empty for a dimensionless channel.
    public let unit: String
    /// The number of decimal places (clamped to `>= 0`).
    public let precision: Int

    public init(unit: String, precision: Int) {
        self.unit = unit
        self.precision = precision
    }

    /// The default formatter for a channel with no configured unit/precision:
    /// two decimals, dimensionless.
    public static let plain = ChannelFormatter(unit: "", precision: 2)

    /// `value` formatted to ``precision`` decimals with the ``unit`` suffix, or
    /// ``ChannelFormatting/emDash`` when it is `nil` or non-finite.
    public func string(for value: Double?) -> String {
        guard let value, value.isFinite else { return ChannelFormatting.emDash }
        // Clamp precision to a sane range: <0 is meaningless, and beyond a
        // Double's significant digits it just prints noise (and a very large
        // width would balloon the string / overflow printf's int precision).
        let places = min(max(0, precision), 15)
        // Fixed POSIX locale so the decimal separator is always ".", stable
        // across machines and asserted against goldens (matches ChannelFormatting).
        var number = String(format: "%.\(places)f",
                            locale: Locale(identifier: "en_US_POSIX"), value)
        // Drop a sign that rounded to zero so a tiny negative / -0.0 doesn't
        // display as "-0.00".
        if number.hasPrefix("-"), Double(number) == 0 { number.removeFirst() }
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}
