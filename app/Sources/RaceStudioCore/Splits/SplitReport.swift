import Foundation

/// One lap's per-segment split times (issue 8.11) — Core's mirror of the FFI
/// `LapSegmentTimes`, so the Split Times report and its consumers never depend on
/// the generated bindings. `baseTimes` is the fine base grid the report groups.
public struct LapSegments: Equatable, Sendable, Identifiable {
    /// The lap these segment times belong to.
    public let lap: LapID
    /// Seconds spent in each fine **base-grid** segment, in track order. Sums to the
    /// lap duration.
    public let baseTimes: [Double]

    public var id: Int { lap.index }
    /// The whole-lap time (the base segment times sum to the lap duration).
    public var total: Double { baseTimes.reduce(0, +) }

    public init(lap: LapID, baseTimes: [Double]) {
        self.lap = lap
        self.baseTimes = baseTimes
    }
}

/// One lap's row in the split-times table (issue 8.11): the seconds spent in each
/// split (grouped from the base grid by the current ``SplitLayout``) and the lap
/// total.
public struct SplitLapRow: Equatable, Sendable, Identifiable {
    public let lap: LapID
    /// Per-split seconds, index-aligned with the layout's splits.
    public let times: [Double]

    public var id: Int { lap.index }
    public var total: Double { times.reduce(0, +) }

    public init(lap: LapID, times: [Double]) {
        self.lap = lap
        self.times = times
    }
}

/// One split's fastest time across all laps (issue 8.11) and the lap that drove it —
/// a component of the ``BestTheoretical`` lap.
public struct SplitBest: Equatable, Sendable, Identifiable {
    public let splitID: Int
    /// The fastest time any lap spent in this split (`0` when there is no data).
    public let time: Double
    /// The lap that drove the fastest time, or `nil` when there is no data.
    public let lap: LapID?

    public var id: Int { splitID }

    public init(splitID: Int, time: Double, lap: LapID?) {
        self.splitID = splitID
        self.time = time
        self.lap = lap
    }
}

/// The best theoretical lap (issue 8.11): the sum of every split's fastest time
/// across the laps — the lap the driver could run by stitching their best sections
/// together.
public struct BestTheoretical: Equatable, Sendable {
    public let total: Double
    /// The fastest time per split, index-aligned with the layout's splits.
    public let perSplit: [SplitBest]

    public init(total: Double, perSplit: [SplitBest]) {
        self.total = total
        self.perSplit = perSplit
    }
}

/// The best rolling lap (issue 8.11): the fastest contiguous one-lap-length stretch
/// of the fine base grid across the whole session — the quickest lap actually
/// driven even if it straddles a start/finish crossing — and where it begins.
public struct BestRolling: Equatable, Sendable {
    public let total: Double
    /// The lap the fastest rolling window starts in, or `nil` when there is no data.
    public let startLap: LapID?
    /// The base-cell offset within `startLap` the window starts at.
    public let startCell: Int

    public init(total: Double, startLap: LapID?, startCell: Int) {
        self.total = total
        self.startLap = startLap
        self.startCell = startCell
    }
}

/// The assembled Split Times report (issue 8.11): the split layout, a row per lap,
/// and the derived best theoretical / best rolling laps.
public struct SplitReport: Equatable, Sendable {
    public let splits: [Split]
    public let rows: [SplitLapRow]
    public let bestTheoretical: BestTheoretical
    public let bestRolling: BestRolling

    /// Whether the report has nothing to render (no laps or no splits).
    public var isEmpty: Bool { rows.isEmpty || splits.isEmpty }

    public init(splits: [Split], rows: [SplitLapRow],
                bestTheoretical: BestTheoretical, bestRolling: BestRolling) {
        self.splits = splits
        self.rows = rows
        self.bestTheoretical = bestTheoretical
        self.bestRolling = bestRolling
    }
}

public extension SplitReport {
    /// Assemble the report for `segments` under `layout` (issue 8.11) — pure, so the
    /// model (and its tests) build it without the FFI.
    ///
    /// Each split's per-lap time is the sum of its base cells; the best theoretical
    /// lap sums the per-split minima across laps; the best rolling lap slides a
    /// one-lap-length window over the base grid concatenated lap after lap.
    static func make(from segments: [LapSegments], layout: SplitLayout) -> SplitReport {
        let rows = segments.map { seg in
            SplitLapRow(lap: seg.lap, times: layout.splits.map { sum(seg.baseTimes, in: $0.range) })
        }
        return SplitReport(splits: layout.splits, rows: rows,
                           bestTheoretical: bestTheoretical(layout: layout, rows: rows),
                           bestRolling: bestRolling(segments: segments, base: layout.base))
    }

    /// The sum of `values` over the half-open `range`, clamped to the array bounds
    /// so a stale range (fewer base cells than expected) never traps.
    private static func sum(_ values: [Double], in range: Range<Int>) -> Double {
        let lo = max(0, range.lowerBound), hi = min(values.count, range.upperBound)
        guard lo < hi else { return 0 }
        return values[lo..<hi].reduce(0, +)
    }

    /// The best theoretical lap: for each split column, the smallest per-lap time
    /// (and the lap that drove it), summed. Ties resolve to the earliest lap.
    private static func bestTheoretical(layout: SplitLayout, rows: [SplitLapRow]) -> BestTheoretical {
        let perSplit = layout.splits.enumerated().map { index, split -> SplitBest in
            var bestTime = Double.infinity
            var bestLap: LapID?
            for row in rows where index < row.times.count && row.times[index] < bestTime {
                bestTime = row.times[index]
                bestLap = row.lap
            }
            return SplitBest(splitID: split.id, time: bestLap == nil ? 0 : bestTime, lap: bestLap)
        }
        return BestTheoretical(total: perSplit.reduce(0) { $0 + $1.time }, perSplit: perSplit)
    }

    /// The best rolling lap: concatenate the base grids lap after lap, then slide a
    /// one-lap-length (`base`) window for the minimum-time contiguous stretch. When
    /// there is less than a full lap of data, the whole stream is reported.
    private static func bestRolling(segments: [LapSegments], base: Int) -> BestRolling {
        var stream: [Double] = []
        var origin: [(lap: LapID, cell: Int)] = []
        for seg in segments {
            for (cell, time) in seg.baseTimes.enumerated() {
                stream.append(time)
                origin.append((seg.lap, cell))
            }
        }
        let window = base > 0 ? base : stream.count
        guard window > 0, stream.count >= window else {
            return BestRolling(total: stream.reduce(0, +),
                               startLap: origin.first?.lap, startCell: origin.first?.cell ?? 0)
        }
        var windowSum = stream.prefix(window).reduce(0, +)
        var bestSum = windowSum
        var bestStart = 0
        var start = 1
        while start <= stream.count - window {
            windowSum += stream[start + window - 1] - stream[start - 1]
            if windowSum < bestSum {
                bestSum = windowSum
                bestStart = start
            }
            start += 1
        }
        return BestRolling(total: bestSum, startLap: origin[bestStart].lap, startCell: origin[bestStart].cell)
    }
}
