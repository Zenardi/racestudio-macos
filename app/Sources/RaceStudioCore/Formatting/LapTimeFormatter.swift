import Foundation

/// Renders a lap/segment time in seconds as `m:ss.mmm` (issue 2.4).
///
/// Sub-hour times drop the hour field (`1:22.248`); hour-plus times include it
/// (`1:01:01.500`). Non-finite or negative input renders the safe placeholder
/// ``placeholder`` rather than a bogus or crashing value.
public enum LapTimeFormatter {

    /// Placeholder shown for missing/invalid times.
    public static let placeholder = "—"

    /// Format `seconds` as `m:ss.mmm` (or `h:mm:ss.mmm` past one hour).
    public static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return placeholder }

        let totalMilliseconds = Int((seconds * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
        }
        return String(format: "%d:%02d.%03d", minutes, secs, milliseconds)
    }
}
