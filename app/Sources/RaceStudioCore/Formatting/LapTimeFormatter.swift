import Foundation

/// Renders a lap/segment time in seconds as `m:ss.mmm` (issue 2.4) — the one
/// lap-time rule in the app, shared by the lap list, the video review grid and
/// the video overlay (issue 9.11).
///
/// Sub-hour times drop the hour field (`1:22.248`); hour-plus times include it
/// (`1:01:01.500`). Non-finite or negative input renders the safe placeholder
/// ``placeholder`` rather than a bogus or crashing value. The decimal mark is
/// `.` unless the caller passes another — the overlay's export locale may want
/// `,`; nothing is read from the machine's locale.
public enum LapTimeFormatter {

    /// Placeholder shown for missing/invalid times.
    public static let placeholder = "—"

    /// Format `seconds` as `m:ss.mmm` (or `h:mm:ss.mmm` past one hour), with
    /// `decimalSeparator` before the milliseconds.
    public static func string(from seconds: Double, decimalSeparator: String = ".") -> String {
        guard let parts = Parts(seconds) else { return placeholder }
        let fraction = decimalSeparator + parts.millisecondsText
        if parts.hours > 0 {
            return String(format: "%d:%02d:%02d", parts.hours, parts.minutes, parts.seconds) + fraction
        }
        return String(format: "%d:%02d", parts.minutes, parts.seconds) + fraction
    }

    /// Format a *sector* (split) time: `s.mmm` under a minute — how split times
    /// are read — and the full ``string(from:decimalSeparator:)`` form from a
    /// minute up. A sector with no time (zero, negative or not finite) is the
    /// ``placeholder``.
    public static func sectorString(from seconds: Double, decimalSeparator: String = ".") -> String {
        guard seconds > 0, let parts = Parts(seconds) else { return placeholder }
        guard parts.hours == 0, parts.minutes == 0 else {
            return string(from: seconds, decimalSeparator: decimalSeparator)
        }
        return "\(parts.seconds)" + decimalSeparator + parts.millisecondsText
    }

    /// A time split into fields after rounding to the millisecond — rounding
    /// first is what carries `59.9996` to `1:00.000` rather than `0:60.000`.
    private struct Parts {
        let hours: Int
        let minutes: Int
        let seconds: Int
        let milliseconds: Int

        /// `nil` for a negative or non-finite time. `isFinite` bounds nothing:
        /// 1e300 is finite and converting it to `Int` traps. A lap duration comes
        /// straight from decoded data, so this is reachable with a corrupt file.
        /// Such a value is not a lap time.
        init?(_ seconds: Double) {
            guard seconds.isFinite, seconds >= 0,
                  let total = Int(exactly: (seconds * 1000).rounded()) else { return nil }
            milliseconds = total % 1000
            self.seconds = (total / 1000) % 60
            minutes = (total / 60_000) % 60
            hours = total / 3_600_000
        }

        var millisecondsText: String { String(format: "%03d", milliseconds) }
    }
}
