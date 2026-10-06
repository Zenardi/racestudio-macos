import Foundation

/// What the Video Review panel reads out about the alignment (issues 9.7 + 9.8)
/// — derived only from the live ``VideoReviewModel/sync`` and
/// ``VideoReviewModel/status``, so it follows every sync action.
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
