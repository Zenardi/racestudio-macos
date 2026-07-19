import Foundation

/// One lap's values fed into the histogram panel (issue 8.9): a stable id, a
/// display label, and the channel's samples inside that lap's window. The panel
/// bins these onto its shared value grid and colours them by position.
public struct LapValues: Equatable, Sendable {
    public let id: LapID
    public let label: String
    public let values: [Double]

    public init(id: LapID, label: String, values: [Double]) {
        self.id = id
        self.label = label
        self.values = values
    }
}

/// One lap's distribution within the histogram panel (issue 8.9): its bins on the
/// panel's shared value grid, a display label, and the deterministic per-lap colour
/// the reused `HistogramView` strokes its bars with.
public struct LapHistogram: Equatable, Sendable {
    public let id: LapID
    public let label: String
    public let color: PlotColor
    public let bins: [Bin]

    public init(id: LapID, label: String, color: PlotColor, bins: [Bin]) {
        self.id = id
        self.label = label
        self.color = color
        self.bins = bins
    }
}

/// Assembles the reused `HistogramView`'s inputs from a channel's window samples
/// (issue 8.9): the whole-window distribution at a configurable bin count, plus —
/// when laps are supplied — one per-lap distribution on a **shared, zero-aligned
/// value grid** so different-range laps are directly comparable, each carrying a
/// deterministic colour keyed to its selection order.
///
/// Pure: the binning is `Histogram.compute` (Core, tested); this only chooses the
/// grid and the colours, so the view stays a thin bars-to-pixels renderer. A
/// value-less input yields no bins; a non-positive bin count degrades to a single
/// bin rather than a blank panel.
public struct HistogramPanelModel: Sendable {

    /// The default bin count — a readable distribution without over-quantising.
    public static let defaultBinCount = 20

    /// The channel whose distribution is shown (empty when none is selected).
    public let channel: String

    /// The effective bin count (the request, clamped to at least one).
    public let binCount: Int

    /// The whole-window distribution — criterion 1's single-channel histogram.
    public let overall: [Bin]

    /// One distribution per supplied lap, in order, each with its colour — criterion
    /// 3's per-lap colouring. Empty when no laps are supplied.
    public let perLap: [LapHistogram]

    /// - Parameters:
    ///   - channel: the channel name (for the panel title).
    ///   - values: the channel's values over the whole window.
    ///   - laps: each selected lap's values, in selection order (colours follow it).
    ///   - binCount: the requested bin count (clamped to `>= 1`).
    public init(channel: String, values: [Double], laps: [LapValues] = [],
                binCount: Int = HistogramPanelModel.defaultBinCount) {
        let bins = max(1, binCount)
        self.channel = channel
        self.binCount = bins
        self.overall = Histogram.compute(values: values, binCount: bins)

        // A single width shared across every lap keeps their bars on one grid; it is
        // derived from the union of the window and all lap values so the grid spans
        // every lap. When there is no spread (all values equal) no width exists, so
        // each lap falls back to its own equal-value single bin.
        let sharedWidth = Self.sharedBinWidth(values: values, laps: laps, binCount: bins)
        self.perLap = laps.enumerated().map { index, lap in
            let lapBins: [Bin]
            if let sharedWidth {
                // The width is positive and each lap's range is a subset of the grid,
                // so the fixed-width binning cannot actually fail here; `?? []` is the
                // safe fallback for the fallible API rather than a force-unwrap.
                lapBins = (try? Histogram.compute(values: lap.values, binWidth: sharedWidth).get()) ?? []
            } else {
                lapBins = Histogram.compute(values: lap.values, binCount: bins)
            }
            return LapHistogram(id: lap.id, label: lap.label,
                                color: PlotColor.selectionColor(at: index), bins: lapBins)
        }
    }

    /// The bin width shared by every lap: the union range of the window and all lap
    /// values split into `binCount` bins, or `nil` when that range has no positive
    /// width (an empty or single-valued distribution has no shared grid).
    private static func sharedBinWidth(values: [Double], laps: [LapValues], binCount: Int) -> Double? {
        var lo = Double.infinity
        var hi = -Double.infinity
        for value in values where value.isFinite { lo = min(lo, value); hi = max(hi, value) }
        for lap in laps {
            for value in lap.values where value.isFinite { lo = min(lo, value); hi = max(hi, value) }
        }
        guard lo < hi else { return nil }
        return (hi - lo) / Double(binCount)
    }
}
