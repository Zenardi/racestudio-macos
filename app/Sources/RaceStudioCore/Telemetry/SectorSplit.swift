import Foundation

/// How a finished sector compares with the best so far (issue 9.17), as an F1
/// broadcast colours it.
public enum SectorPace: Equatable, Sendable {
    /// At or under the best so far in this sector — purple.
    case best
    /// Over it — yellow.
    case slower
    /// Not compared: nothing to compare with yet, a lap that doesn't count
    /// (the out-lap or the in-lap), or a sector with no time — neutral.
    case unrated
}

/// One sector of the lap under an instant, as the sector splits show it (issue
/// 9.17): done with its time and its gap to the best so far, running with its
/// time so far, or still to come.
public struct SectorSplit: Equatable, Sendable {

    /// Where the instant is in the sector.
    public enum Progress: Equatable, Sendable {
        /// Finished in `time` seconds, `gap` seconds off the best so far
        /// (negative: faster; `nil` when not compared).
        case done(time: Double, gap: Double?, pace: SectorPace)
        /// Being driven, `elapsed` seconds in.
        case running(elapsed: Double)
        /// Still to come.
        case upcoming
    }

    /// The split's display name (`"S1"`, … or a renamed one).
    public let name: String
    public let progress: Progress

    public init(name: String, progress: Progress) {
        self.name = name
        self.progress = progress
    }

    /// The sectors of `lap` at session time `time`, in track order, compared
    /// with `reading`'s sector bests so far.
    ///
    /// A sector is done once `time` reaches its end (its window is half-open,
    /// so the boundary opens the next one). The gap is taken on the thousandths
    /// a sector time shows, so the colour always agrees with the gap's text: a
    /// gap that reads `0.000` equals the best, and is purple.
    public static func splits(of lap: LapSpan, at time: Double, reading: LapClockReading) -> [SectorSplit] {
        let counts = !reading.isOutLap && !reading.isInLap
        return lap.sectors.map { sector in
            if time >= sector.span.end {
                let best = counts ? reading.sectorBestsSoFar[sector.splitID] : nil
                return SectorSplit(name: sector.name, progress: done(sector.duration, against: best))
            }
            if sector.span.contains(time) {
                return SectorSplit(name: sector.name, progress: .running(elapsed: time - sector.span.start))
            }
            return SectorSplit(name: sector.name, progress: .upcoming)
        }
    }

    /// A sector done in `time`, compared with `best` when there is one.
    private static func done(_ time: Double, against best: Double?) -> Progress {
        guard let best, time > 0, time.isFinite, best.isFinite else {
            return .done(time: time, gap: nil, pace: .unrated)
        }
        let gap = ((time * 1000).rounded() - (best * 1000).rounded()) / 1000
        return .done(time: time, gap: gap, pace: gap <= 0 ? .best : .slower)
    }
}
