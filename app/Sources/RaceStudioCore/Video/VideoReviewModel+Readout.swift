import Foundation

/// What the Video Review panel reads out (issues 9.6 – 9.8): the section under
/// review, and the alignment — derived only from the live
/// ``VideoReviewModel/sync`` and ``VideoReviewModel/status``, so it follows
/// every sync action.
public extension VideoReviewModel {

    /// Which laps the aligned footage covers in full — the status line's second
    /// half.
    var coverageSummary: CoverageSummary { CoverageSummary.make(timeline: timeline, sync: sync) }

    /// The panel's status line, e.g. "Synced on lap 3 + lap 14 · footage covers
    /// laps 2–15 (14 of 16)".
    func statusLine(locale: Locale = .current) -> String {
        status.statusLine(coverage: coverageSummary, locale: locale)
    }

    /// The offset readout (``VideoSyncModel/readout(offset:locale:)``) plus the
    /// clock rate once a two-point sync solved one: `"+12.500 s ×1.000083"`.
    func offsetReadout(locale: Locale = .current) -> String {
        let offset = VideoSyncModel.readout(offset: sync.offset, locale: locale)
        guard sync.rate != 1 else { return offset }
        return offset + " ×" + L10n.formattedNumber(sync.rate, fractionDigits: 6, locale: locale)
    }
}

public extension VideoReviewModel {

    /// The section under review, named the way the readout names it —
    /// `"Lap 2"` or `"Lap 2 · S1"`.
    var selectedLabel: String? {
        guard let lap = selectedLap else { return nil }
        if let splitID = selectedSplitID, let sector = timeline.sector(lap: lap, splitID: splitID) {
            return Self.label(lap: lap, sector: sector.name)
        }
        return timeline.lapSpan(lap).map { Self.label(lap: $0.lap, sector: nil) }
    }

    /// The lap and sector the cursor is passing through at `time`, named for the
    /// panel's readout, or `nil` outside every lap.
    func label(atSessionTime time: Double) -> String? {
        guard let location = timeline.location(atSessionTime: time) else { return nil }
        return Self.label(lap: location.lap, sector: location.sector?.name)
    }

    private static func label(lap: LapID, sector: String?) -> String {
        // Laps read 1-based everywhere in the UI, matching the lap picker.
        let base = "Lap \(lap.index + 1)"
        guard let sector else { return base }
        return "\(base) · \(sector)"
    }
}

public extension VideoSyncModel {

    /// An offset as the panel reads it: signed, to the millisecond, in the
    /// locale's digits — a 29.97 fps frame step reads `+0.033 s`, a proposal
    /// `−113,632 s` in pt-BR. Signed as shown, so a sub-millisecond negative
    /// offset reads `+0.000 s` rather than `−0.000 s`.
    static func readout(offset: Double, locale: Locale = .current) -> String {
        let milliseconds = (offset * 1_000).rounded()
        let sign = milliseconds < 0 ? "−" : "+"
        return sign + L10n.formattedNumber(abs(milliseconds) / 1_000, fractionDigits: 3, locale: locale) + " s"
    }
}
