import Foundation

/// Presentation helpers for the summary screen (issue 2.4): channel sample-rate
/// formatting, the stable metadata date formatter, and the empty-field fallback.
///
/// All formatters are locale-fixed (`en_US_POSIX`) so rendered strings are
/// stable across machines and asserted against the golden.
public enum ChannelFormatting {

    /// Placeholder for an empty/unknown field.
    public static let emDash = "—"

    /// `value` if non-empty, otherwise ``emDash``.
    public static func orEmDash(_ value: String) -> String {
        value.isEmpty ? emDash : value
    }

    /// Format a sample rate as e.g. `"50 Hz"` (integer) or `"12.5 Hz"`
    /// (fractional). A non-positive or non-finite rate renders ``emDash``.
    ///
    /// Whole rates drop the fraction; otherwise `Double`'s locale-independent
    /// description is used (always a `.` decimal), so the output is stable.
    public static func rate(hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return emDash }
        // Only take the whole-number path when `hz` is safely within `Int` range
        // (well beyond any real sample rate); `Int(hz)` traps on out-of-range
        // doubles. Larger values fall back to the raw description.
        let value = (hz == hz.rounded() && hz < 1e15) ? String(Int(hz)) : "\(hz)"
        return "\(value) Hz"
    }

    /// Format a UTC epoch-seconds timestamp with the fixed metadata formatter.
    /// Zero (absent/unparseable) renders ``emDash``.
    public static func date(epochSeconds: Int64) -> String {
        guard epochSeconds != 0 else { return emDash }
        return metadataDateFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    /// Fixed-locale, UTC metadata date formatter (e.g. `Jan 23, 2016 at 12:09 PM`).
    public static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter
    }()
}
