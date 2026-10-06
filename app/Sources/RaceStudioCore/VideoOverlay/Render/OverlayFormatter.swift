import Foundation

/// How the video overlay writes its numbers (issue 9.11): fixed for one export,
/// injected into the ``OverlayRenderer`` — never read from the machine — so the
/// same frame renders the same text on every Mac, and the live HUD matches the
/// MP4.
///
/// The export ``locale`` decides only the decimal mark (`.` for English, `,` for
/// Brazilian Portuguese) and the language of the widgets' labels. Numbers have
/// no grouping separator (`12345` rpm), negatives take a true minus sign
/// (`−0.41`, U+2212), and every missing or unusable value — a channel gap, no
/// lap, a corrupt sample — is an em dash `—`, never a stale or zero value.
public struct OverlayFormatter: Equatable, Sendable {

    /// What a missing value reads as.
    public static let missing = ChannelFormatting.emDash
    /// The most decimals a number is drawn with.
    public static let maximumDecimals = 6

    /// The export locale: the decimal mark and the labels' language.
    public let locale: Locale
    /// The decimal mark: `,` when the locale writes one, else `.`.
    public let decimalSeparator: String

    /// - Parameter locale: the export locale; the default is locale-neutral
    ///   English (`.` decimals, English labels).
    public init(locale: Locale = Locale(identifier: "en_US_POSIX")) {
        self.locale = locale
        self.decimalSeparator = locale.decimalSeparator == "," ? "," : "."
    }

    /// A lap time, `m:ss.mmm` (the shared ``LapTimeFormatter`` rule).
    public func lapTime(_ seconds: Double?) -> String {
        guard let seconds else { return Self.missing }
        return LapTimeFormatter.string(from: seconds, decimalSeparator: decimalSeparator)
    }

    /// A sector time: `s.mmm` under a minute, `m:ss.mmm` from a minute.
    public func sectorTime(_ seconds: Double?) -> String {
        guard let seconds else { return Self.missing }
        return LapTimeFormatter.sectorString(from: seconds, decimalSeparator: decimalSeparator)
    }

    /// A delta to the reference lap in seconds, to the hundredth and always
    /// signed — `+0.23` losing, `−0.41` gaining — except a delta that rounds to
    /// zero, which is `0.00`.
    public func delta(_ seconds: Double?) -> String {
        format(seconds, decimals: 2, signsPositive: true)
    }

    /// `value` with `decimals` places (clamped to `0…`` ``maximumDecimals``),
    /// rounded half away from zero; `—` when missing, not finite, or too large
    /// to be a reading (a trillion or more).
    public func number(_ value: Double?, decimals: Int) -> String {
        format(value, decimals: decimals, signsPositive: false)
    }

    /// A gear: `N` for neutral (`0`), else the whole gear number; `—` when
    /// missing or negative.
    public func gear(_ value: Double?) -> String {
        guard let value, value.isFinite, let gear = Int(exactly: value.rounded()), gear >= 0,
              gear < Self.largest else { return Self.missing }
        return gear == 0 ? "N" : String(gear)
    }

    // MARK: - Internals

    /// The magnitude from which a value is no reading.
    private static let largest = 1_000_000_000_000

    private func format(_ value: Double?, decimals: Int, signsPositive: Bool) -> String {
        guard let value, value.isFinite else { return Self.missing }
        let places = min(max(decimals, 0), Self.maximumDecimals)
        var unit = 1
        for _ in 0..<places { unit *= 10 }
        guard abs(value) < Double(Self.largest),
              let scaled = Int(exactly: (abs(value) * Double(unit)).rounded()) else { return Self.missing }
        // A value that rounds to zero is zero — never "−0.0" or "+0.00".
        let sign = scaled == 0 ? "" : value < 0 ? "\u{2212}" : signsPositive ? "+" : ""
        let whole = String(scaled / unit)
        guard places > 0 else { return sign + whole }
        let fraction = String(scaled % unit)
        return sign + whole + decimalSeparator + String(repeating: "0", count: places - fraction.count) + fraction
    }
}
