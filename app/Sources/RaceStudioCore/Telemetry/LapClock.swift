import Foundation

/// A completed lap's time, as the lap widgets show it (issue 9.9).
public struct LapTiming: Equatable, Sendable {
    /// The lap.
    public let lap: LapID
    /// Its 1-based number, as the lap list shows it.
    public let number: Int
    /// Its time (seconds).
    public let time: Double

    public init(lap: LapID, number: Int, time: Double) {
        self.lap = lap
        self.number = number
        self.time = time
    }
}

/// The lap timer at one session instant (issue 9.9): the lap the kart is on,
/// how long it has been on it, its reference times, and where in the lap it is.
public struct LapClockReading: Equatable, Sendable {
    /// The lap holding the instant.
    public let lap: LapID
    /// Its 1-based number, as the lap list shows it.
    public let number: Int
    /// Seconds since the lap's beacon — the running lap time.
    public let elapsed: Double
    /// The most recent completed lap with a valid time, or `nil` on the first.
    public let last: LapTiming?
    /// The session's best lap — the one the Summary and library flag.
    public let best: LapTiming?
    /// The best of the laps completed *before* this one (same rule) — what a
    /// live lap timer shows; `nil` until a valid lap has been completed.
    public let bestSoFar: LapTiming?
    /// The session's first lap — driven out of the pits.
    public let isOutLap: Bool
    /// The session's last lap (in a multi-lap session) — driven back in.
    public let isInLap: Bool
    /// The sector under the instant, when the split timeline divided this lap.
    public let sector: SectorSpan?

    public init(lap: LapID, number: Int, elapsed: Double, last: LapTiming?, best: LapTiming?,
                bestSoFar: LapTiming?, isOutLap: Bool, isInLap: Bool, sector: SectorSpan?) {
        self.lap = lap
        self.number = number
        self.elapsed = elapsed
        self.last = last
        self.best = best
        self.bestSoFar = bestSoFar
        self.isOutLap = isOutLap
        self.isInLap = isInLap
        self.sector = sector
    }
}

/// Lap number, running time, last/best lap, out/in-lap flags and sector at any
/// session time (issue 9.9) — the lap timer and lap-info widgets' data.
///
/// Built once from the session's laps and the split timeline; a read is a
/// binary search over the lap windows, or O(1) with a carried hint. Lap windows
/// are ``LapSectorTimeline``'s (half-open, the session's last instant closing
/// the final lap) and "best" is ``SessionSummaryViewModel``'s rule, so the
/// overlay agrees with the review grid, the Summary and the library. The one
/// exception is malformed input with overlapping laps (the decoder's laps are
/// contiguous): the clock cuts an overlap at the next beacon, giving the later
/// lap, where the review grid's lookup takes the first listed.
public struct LapClock: Equatable, Sendable {

    /// The session's best lap (fastest valid, earliest on a tie), or `nil` when
    /// no lap is valid.
    public let best: LapTiming?

    /// One reviewable lap, in window order, with everything a reading needs
    /// precomputed.
    private struct Entry: Equatable, Sendable {
        let lap: LapID
        let number: Int
        let window: SessionTimeSpan
        let last: LapTiming?
        let bestSoFar: LapTiming?
        let isOutLap: Bool
        let isInLap: Bool
        let sectors: LapSpan?
    }

    private let entries: [Entry]

    /// - Parameters:
    ///   - laps: the session's laps, in session order.
    ///   - sectors: the split timeline naming each lap's sectors (``LapSectorTimeline/empty``
    ///     for none).
    public init(laps: [Lap], sectors: LapSectorTimeline = .empty) {
        self.best = Self.timing(SessionSummaryViewModel.bestLapIndex(laps).map { laps[$0] })
        var entries: [Entry] = []
        var lastValid: Lap?
        var bestSoFar: Lap?
        for (position, lap) in laps.enumerated() {
            if let window = LapSectorTimeline.window(of: lap), window.end > window.start {
                let id = LapID(Int(lap.index))
                entries.append(Entry(lap: id, number: Int(lap.index) + 1, window: window,
                                     last: Self.timing(lastValid), bestSoFar: Self.timing(bestSoFar),
                                     isOutLap: position == 0, isInLap: laps.count > 1 && position == laps.count - 1,
                                     sectors: sectors.lapSpan(id)))
            }
            if lap.hasValidDuration { lastValid = lap }
            // The shared rule over (best so far, this lap) — the earlier wins a
            // tie — equals the rule over every lap so far, in one pass.
            let contenders = [bestSoFar, lap].compactMap { $0 }
            bestSoFar = SessionSummaryViewModel.bestLapIndex(contenders).map { contenders[$0] }
        }
        self.entries = Self.disjoint(entries)
    }

    /// The lap timer at session time `t`, or `nil` when `t` is outside every
    /// valid lap (or not finite).
    public func reading(at t: Double) -> LapClockReading? {
        var hint = -1
        return reading(at: t, hint: &hint)
    }

    /// The lap timer at `t`, reusing `hint` (the entry that held the previous
    /// read) so a forward sweep skips the search; any hint is safe.
    public func reading(at t: Double, hint: inout Int) -> LapClockReading? {
        guard let index = entryIndex(at: t, hint: &hint) else { return nil }
        let entry = entries[index]
        return LapClockReading(
            lap: entry.lap, number: entry.number, elapsed: t - entry.window.start,
            last: entry.last, best: best, bestSoFar: entry.bestSoFar,
            isOutLap: entry.isOutLap, isInLap: entry.isInLap,
            sector: entry.sectors.flatMap { LapSectorTimeline.sector(in: $0, at: t) })
    }

    // MARK: - Internals

    /// The entry whose window holds `t`: the hinted entry or its successor when
    /// they hold it, else a binary search for the last window starting at or
    /// before `t`. Updates `hint`.
    private func entryIndex(at t: Double, hint: inout Int) -> Int? {
        guard t.isFinite, !entries.isEmpty else { return nil }
        if holds(hint, t) { return hint }
        if hint < entries.count - 1, holds(hint + 1, t) {
            hint += 1
            return hint
        }
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].window.start <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0, holds(low - 1, t) else { return nil }
        hint = low - 1
        return low - 1
    }

    /// Whether entry `index` exists and holds `t`: inside its half-open window,
    /// or the session's final instant closing the last lap.
    private func holds(_ index: Int, _ t: Double) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let window = entries[index].window
        return window.contains(t) || (index == entries.count - 1 && t == window.end)
    }

    /// `entries` in start order (session order on a tie) with each window cut
    /// at the next lap's beacon — which opens the next lap — so no instant
    /// belongs to two laps and the hinted and searched lookups always agree. A
    /// lap left with no time at all (two laps starting together) is dropped.
    /// Only malformed input overlaps: the decoder's laps are contiguous.
    private static func disjoint(_ entries: [Entry]) -> [Entry] {
        let ordered = entries.enumerated()
            .sorted { ($0.element.window.start, $0.offset) < ($1.element.window.start, $1.offset) }
            .map(\.element)
        return ordered.indices.compactMap { index in
            let entry = ordered[index]
            let nextStart = index + 1 < ordered.count ? ordered[index + 1].window.start : .infinity
            let end = Swift.min(entry.window.end, nextStart)
            guard end > entry.window.start else { return nil }
            return Entry(lap: entry.lap, number: entry.number,
                         window: SessionTimeSpan(start: entry.window.start, end: end), last: entry.last,
                         bestSoFar: entry.bestSoFar, isOutLap: entry.isOutLap, isInLap: entry.isInLap,
                         sectors: entry.sectors)
        }
    }

    private static func timing(_ lap: Lap?) -> LapTiming? {
        lap.map { LapTiming(lap: LapID(Int($0.index)), number: Int($0.index) + 1, time: $0.durationS) }
    }
}
