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

    /// `value` formatted to ``precision`` decimals with the ``unit`` suffix, or
    /// ``ChannelFormatting/emDash`` when it is `nil` or non-finite.
    public func string(for value: Double?) -> String {
        guard let value, value.isFinite else { return ChannelFormatting.emDash }
        // Fixed POSIX locale so the decimal separator is always ".", stable
        // across machines and asserted against goldens (matches ChannelFormatting).
        let number = String(format: "%.\(max(0, precision))f",
                            locale: Locale(identifier: "en_US_POSIX"), value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}
