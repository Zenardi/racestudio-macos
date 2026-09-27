import Foundation

/// Rendering for a session's recorded timestamp.
///
/// An AiM logger writes local wall-clock with **no timezone** (`TMD`/`TMT`), and
/// the decoder turns that pair into an epoch by reading it as UTC
/// (`parse_datetime_utc`). The stored `Date` is therefore a *floating* wall clock,
/// not a true instant: formatting it in the viewer's zone shifts it by their UTC
/// offset, which is why a session logged at 14:18 in São Paulo listed as 11:18.
///
/// Session timestamps are consequently always rendered in GMT, reproducing the
/// digits the logger wrote whatever zone the reader is in. Genuine instants — an
/// `importedAt` stamped by `Date()` — take ``instantText(_:timeZone:locale:)``
/// instead and do localise. Keeping both rules here, named apart, is what stops
/// the two being confused again at a call site.
public enum SessionDate {

    /// Shown for a session whose header carried no parseable date.
    public static let unknownText = "Date unknown"

    /// The zone session timestamps are formatted in: GMT, so the rendered clock is
    /// the logger's own.
    public static let displayTimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// Whether `date` is the decoder's "no date" sentinel (`datetime_utc == 0`).
    /// Such a session is reported as unknown rather than listed under 1 Jan 1970.
    public static func isUnset(_ date: Date) -> Bool {
        date.timeIntervalSince1970 == 0
    }

    /// The wall-clock components the logger recorded.
    public static func components(of date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = displayTimeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// The logger's own encoding, `MM/dd/yyyy HH:mm:ss` — locale-independent, so it
    /// round-trips the `TMD`/`TMT` header fields exactly.
    public static func loggerText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Locale-aware display text for a session timestamp, in ``displayTimeZone``.
    public static func text(
        _ date: Date, locale: Locale = .current,
        dateStyle: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .short
    ) -> String {
        guard !isUnset(date) else { return unknownText }
        return formatted(date, timeZone: displayTimeZone, locale: locale,
                         dateStyle: dateStyle, timeStyle: timeStyle)
    }

    /// Locale-aware display text for a genuine instant (e.g. when a session was
    /// imported), in the viewer's own zone — the opposite rule to ``text(_:_:_:_:)``.
    public static func instantText(
        _ date: Date, timeZone: TimeZone = .current, locale: Locale = .current,
        dateStyle: DateFormatter.Style = .medium, timeStyle: DateFormatter.Style = .short
    ) -> String {
        formatted(date, timeZone: timeZone, locale: locale,
                  dateStyle: dateStyle, timeStyle: timeStyle)
    }

    private static func formatted(
        _ date: Date, timeZone: TimeZone, locale: Locale,
        dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}
