import Foundation

/// Renders a time position or duration as `mm:ss.mmm` — the form on every timing
/// board — instead of raw milliseconds or bare seconds.
///
/// A predictive time of `40701 ms` tells a driver nothing; `00:40.701` is
/// immediately legible. Five channels in a real AiM session carry the unit `ms`
/// (Predictive Time, Best Run Diff, Best Today Diff, Prev Lap Diff, Ref Lap Diff),
/// and the analysis cursor reports its position in seconds.
///
/// Milliseconds are **kept**: this is lap timing, where a tenth separates sessions,
/// so truncating to whole seconds would drop the only digits that matter. Minutes
/// are zero-padded so a column of values lines up; an hour or more promotes the hour
/// to its own field, since `90:00.000` reads ambiguously.
///
/// Distinct from ``LapTimeFormatter``, which renders a *lap* time as `m:ss.mmm`
/// (unpadded, non-negative only). This one also handles the signed gaps the "Diff"
/// channels report, where the sign is the point.
public enum TimecodeFormatter {

    /// `seconds` as `mm:ss.mmm` (or `h:mm:ss.mmm` past an hour), signed when
    /// negative. A `nil` or non-finite value renders ``ChannelFormatting/emDash``.
    public static func string(from seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return ChannelFormatting.emDash }
        // `isFinite` does not bound the magnitude — 1e300 is finite, and converting
        // it to `Int` *traps*. A channel value is whatever the decoder produced, so a
        // corrupt sample would otherwise crash the app while drawing a readout. A
        // value that large is not a time; it reports as absent.
        guard let totalMilliseconds = Int(exactly: (abs(seconds) * 1000).rounded()) else {
            return ChannelFormatting.emDash
        }
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        // A value that rounds to zero is zero — never "-00:00.000".
        let sign = seconds < 0 && totalMilliseconds > 0 ? "-" : ""

        if hours > 0 {
            return String(format: "%@%d:%02d:%02d.%03d", sign, hours, minutes, secs, milliseconds)
        }
        return String(format: "%@%02d:%02d.%03d", sign, minutes, secs, milliseconds)
    }

    /// As ``string(from:)``, for a value already in milliseconds — the unit the
    /// decoder reports for the timing channels.
    public static func string(fromMilliseconds milliseconds: Double?) -> String {
        string(from: milliseconds.map { $0 / 1000 })
    }

    /// The channel unit that marks a value as a time in milliseconds.
    public static let millisecondUnit = "ms"

    /// Whether a channel carrying `unit` should be rendered as a timecode.
    public static func isTimeUnit(_ unit: String) -> Bool {
        unit.caseInsensitiveCompare(millisecondUnit) == .orderedSame
    }
}
