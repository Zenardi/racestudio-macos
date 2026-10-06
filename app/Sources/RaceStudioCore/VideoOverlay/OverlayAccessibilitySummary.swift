import Foundation

/// The live HUD's VoiceOver value (issue 9.12): one sentence of what the
/// overlay shows at the cursor — `"Lap 7, 1:02.3, speed 84 km/h, delta minus
/// 0.21"` — so a VoiceOver user hears the numbers a sighted one reads off the
/// footage.
///
/// Speed is spoken in the layout's ``UnitSystem``, numbers in the reader's
/// locale. Whatever the session cannot say at that instant (a gap, no lap, no
/// delta) is left out — never read as zero — and a frame with nothing to say
/// reads "No telemetry here".
public enum OverlayAccessibilitySummary {

    /// The sentence for `frame` (or `nil`, no frame yet).
    public static func text(for frame: TelemetryFrame?, units: UnitSystem = .metric,
                            locale: Locale = .current) -> String {
        guard let frame else { return L10n.string(.hudSummaryNoData, locale: locale) }
        let parts = [lap(frame.lap, locale: locale), speed(frame.speed, units: units, locale: locale),
                     delta(frame.delta, locale: locale)].compactMap { $0 }
        return parts.isEmpty ? L10n.string(.hudSummaryNoData, locale: locale) : parts.joined(separator: ", ")
    }

    // MARK: - Parts

    /// "Lap 7, 1:02.3" — or just "Lap 7" when the running time is unusable.
    private static func lap(_ reading: LapClockReading?, locale: Locale) -> String? {
        guard let reading else { return nil }
        let number = String(reading.number)
        guard let time = tenths(reading.elapsed, locale: locale) else {
            return L10n.format(.hudSummaryLapNumber, locale: locale, number)
        }
        return L10n.format(.hudSummaryLap, locale: locale, number, time)
    }

    /// "speed 84 km/h", rounded to the whole unit.
    private static func speed(_ kilometresPerHour: Double?, units: UnitSystem, locale: Locale) -> String? {
        guard let kilometresPerHour, kilometresPerHour.isFinite else { return nil }
        let value = L10n.formattedNumber(units.speed(fromKilometresPerHour: kilometresPerHour).rounded(),
                                         fractionDigits: 0, locale: locale)
        return L10n.format(.hudSummarySpeed, locale: locale, value, units.speedUnit)
    }

    /// "delta minus 0.21" gaining, "delta plus 0.40" losing, "delta 0.00" level.
    private static func delta(_ seconds: Double?, locale: Locale) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        let hundredths = (seconds * 100).rounded()
        let magnitude = L10n.formattedNumber(abs(hundredths) / 100, fractionDigits: 2, locale: locale)
        if hundredths < 0 { return L10n.format(.hudSummaryDeltaMinus, locale: locale, magnitude) }
        if hundredths > 0 { return L10n.format(.hudSummaryDeltaPlus, locale: locale, magnitude) }
        return L10n.format(.hudSummaryDeltaLevel, locale: locale, magnitude)
    }

    /// A running lap time to the tenth, `m:ss.d`, in `locale`'s decimal mark;
    /// `nil` for a time that is not one (negative, not finite, absurdly long).
    private static func tenths(_ seconds: Double, locale: Locale) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 360_000,
              let total = Int(exactly: (seconds * 10).rounded()) else { return nil }
        let minutes = total / 600, wholeSeconds = (total / 10) % 60, tenth = total % 10
        let separator = locale.decimalSeparator ?? "."
        return "\(minutes):" + String(format: "%02d", wholeSeconds) + separator + String(tenth)
    }
}
