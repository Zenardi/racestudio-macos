import Foundation

/// A window of **session time** in seconds — the span a lap or one of its
/// sectors occupies on the shared cursor's clock (issue 9.6).
///
/// Windows are half-open (``contains(_:)`` is `start ..< end`) so adjacent
/// sectors tile a lap without a time belonging to two of them; the very last
/// instant of a lap is resolved by ``LapSectorTimeline/location(atSessionTime:)``
/// rather than by widening the window. A reversed or empty span reports zero
/// ``duration`` instead of a negative one.
public struct SessionTimeSpan: Equatable, Sendable {
    /// Session-relative start (seconds), inclusive.
    public let start: Double
    /// Session-relative end (seconds), exclusive.
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// The seconds the window covers; `0` for an empty or reversed span.
    public var duration: Double { Swift.max(0, end - start) }

    /// Whether `time` falls in `[start, end)`. A non-finite time is in no window.
    public func contains(_ time: Double) -> Bool {
        time.isFinite && time >= start && time < end
    }
}

/// One sector of one lap placed on the session clock (issue 9.6): the 8.11
/// ``Split`` it comes from, resolved against a specific lap's base grid.
public struct SectorSpan: Equatable, Sendable, Identifiable {
    /// The lap this sector belongs to.
    public let lap: LapID
    /// The ``Split/id`` of the split it was cut from — the report's column.
    public let splitID: Int
    /// The split's display name (`"S1"`, `"S2"`, … or a renamed one).
    public let name: String
    /// 0-based position within the lap, in track order.
    public let index: Int
    /// The absolute session-time window the sector occupies.
    public let span: SessionTimeSpan

    /// Stable across laps *and* columns — a grid cell's identity.
    public var id: String { "\(lap.index)#\(splitID)" }
    /// The time spent in this sector (the 8.11 split time for this lap).
    public var duration: Double { span.duration }

    public init(lap: LapID, splitID: Int, name: String, index: Int, span: SessionTimeSpan) {
        self.lap = lap
        self.splitID = splitID
        self.name = name
        self.index = index
        self.span = span
    }
}

/// One lap placed on the session clock, with the sectors it was cut into.
public struct LapSpan: Equatable, Sendable, Identifiable {
    public let lap: LapID
    /// The lap's absolute `[start, end)` session-time window.
    public let span: SessionTimeSpan
    /// The lap's sectors in track order — empty when the core returned no base
    /// grid for it (the lap is then navigable, but not divisible).
    public let sectors: [SectorSpan]

    public var id: Int { lap.index }

    public init(lap: LapID, span: SessionTimeSpan, sectors: [SectorSpan]) {
        self.lap = lap
        self.span = span
        self.sectors = sectors
    }
}

/// The session's laps and sectors placed on one absolute time axis (issue 9.6).
///
/// The 8.11 report gives *durations* (seconds spent in each base cell, per lap);
/// reviewing footage needs *positions* — where on the session clock a lap or a
/// sector begins and ends — so the player can be sent to a section and stopped at
/// its end. This type is that conversion, and the reverse lookup that names the
/// section under the cursor.
///
/// It is derived purely from the laps, the base grid, and the current
/// ``SplitLayout``, so the video grid and the Split Times table can never
/// disagree: both sum the same base cells.
public struct LapSectorTimeline: Equatable, Sendable {

    /// Where a session time falls: always a lap, and the sector inside it when the
    /// lap was divisible and the instant lands in one.
    public struct Location: Equatable, Sendable {
        public let lap: LapID
        public let sector: SectorSpan?

        public init(lap: LapID, sector: SectorSpan?) {
            self.lap = lap
            self.sector = sector
        }
    }

    /// The reviewable laps, in session order.
    public let laps: [LapSpan]

    /// The timeline of a session with nothing to review.
    public static let empty = LapSectorTimeline(laps: [])

    public init(laps: [LapSpan]) {
        self.laps = laps
    }

    /// Whether there is nothing to review.
    public var isEmpty: Bool { laps.isEmpty }

    /// Every sector of every lap, flattened in session order — the review grid.
    public var sectors: [SectorSpan] { laps.flatMap(\.sectors) }

    /// Place `laps` and their 8.11 base grids on the session clock under `layout`.
    ///
    /// A lap with no matching ``LapSegments`` keeps its lap window but gets no
    /// sectors (it stays navigable); a lap with no valid duration is not reviewable
    /// and is left out entirely. A layout finer than the returned grid clamps, so a
    /// stale split range can never read past the cells that exist.
    public static func make(laps: [Lap], segments: [LapSegments], layout: SplitLayout) -> LapSectorTimeline {
        var grids: [LapID: [Double]] = [:]
        for segment in segments { grids[segment.lap] = segment.baseTimes }

        return LapSectorTimeline(laps: laps.compactMap { lap in
            guard lap.hasValidDuration, lap.startTimeS.isFinite else { return nil }
            let id = LapID(Int(lap.index))
            let end = lap.endTimeS.isFinite ? lap.endTimeS : lap.startTimeS + lap.durationS
            let window = SessionTimeSpan(start: lap.startTimeS, end: end)
            guard let grid = grids[id], !grid.isEmpty else {
                return LapSpan(lap: id, span: window, sectors: [])
            }
            return LapSpan(lap: id, span: window,
                           sectors: cut(lap: id, from: lap.startTimeS, grid: grid, layout: layout))
        })
    }

    /// The lap with `id`, or `nil` when it is not reviewable.
    public func lapSpan(_ id: LapID) -> LapSpan? {
        laps.first { $0.lap == id }
    }

    /// The sector cut from `splitID` in `lap`, or `nil` when either is unknown.
    public func sector(lap: LapID, splitID: Int) -> SectorSpan? {
        lapSpan(lap)?.sectors.first { $0.splitID == splitID }
    }

    /// The lap — and, when the instant lands in one, the sector — holding
    /// `time`, or `nil` when it falls outside every lap.
    ///
    /// Windows are half-open, so a boundary opens the following section. The
    /// session's very last instant is the one exception: it closes the final lap
    /// (and its final sector) rather than resolving to nothing.
    public func location(atSessionTime time: Double) -> Location? {
        guard time.isFinite, let lap = lap(containing: time) else { return nil }
        return Location(lap: lap.lap, sector: Self.sector(in: lap, at: time))
    }

    // MARK: - Internals

    private func lap(containing time: Double) -> LapSpan? {
        if let match = laps.first(where: { $0.span.contains(time) }) { return match }
        // The session's last instant closes the final lap instead of falling off
        // the end of the half-open windows.
        if let last = laps.last, time == last.span.end { return last }
        return nil
    }

    private static func sector(in lap: LapSpan, at time: Double) -> SectorSpan? {
        if let match = lap.sectors.first(where: { $0.span.contains(time) }) { return match }
        // As above, but a zero-length sector (a split with no cells behind it)
        // never claims an instant.
        if let last = lap.sectors.last, last.duration > 0, time == last.span.end { return last }
        return nil
    }

    /// Cut `grid` into one sector per split, positioned from the lap's start.
    ///
    /// The running sum ignores a non-finite or negative cell (it contributes zero)
    /// so one bad sample can never poison every later sector's window, and each
    /// split's cell range is clamped to the cells that actually came back.
    private static func cut(lap: LapID, from start: Double,
                            grid: [Double], layout: SplitLayout) -> [SectorSpan] {
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(grid.count + 1)
        var running = 0.0
        for cell in grid {
            running += (cell.isFinite && cell > 0) ? cell : 0
            cumulative.append(running)
        }

        return layout.splits.enumerated().map { index, split in
            let low = Swift.min(Swift.max(split.range.lowerBound, 0), grid.count)
            let high = Swift.min(Swift.max(split.range.upperBound, low), grid.count)
            return SectorSpan(
                lap: lap, splitID: split.id, name: split.name, index: index,
                span: SessionTimeSpan(start: start + cumulative[low], end: start + cumulative[high]))
        }
    }
}
