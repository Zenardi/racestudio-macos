import Foundation

/// The assembled inputs for the reused `TrackMapView` (issue 8.6): the racing-line
/// coordinates and their per-fix cumulative distances, the colour channel's value
/// interpolated onto each fix, the colour scale spanning that channel's range, and
/// the total lap distance — plus the cursor↔fix-index mapping that keeps the map
/// marker synced to the shared cursor.
///
/// A pure value derived from a GPS track (issue 8.2's ``GPSTrackPoint`` rows) and
/// an optional colour ``ChannelSeries``, so all of its geometry / alignment is
/// covered in Core without the FFI or SwiftUI. The view stays thin: it strokes the
/// coordinates, colours each segment with ``colorScale``, and turns a click into a
/// fix index — every decision here is tested.
public struct TrackMapModel: Sendable {

    /// The racing-line coordinates, in fix order.
    public let coordinates: [GPSCoord]

    /// Cumulative track distance (metres) at each coordinate — the axis the sector
    /// boundary marks are placed along.
    public let distances: [Double]

    /// Logger time (seconds) at each fix, ascending — the basis the shared cursor
    /// maps onto for the marker position.
    public let times: [Double]

    /// The colour channel's value at each fix (interpolated onto the fix times), or
    /// empty when no colour channel is set — then the line renders neutral.
    public let channelValues: [Double]

    /// The colour-by-channel gradient, its domain spanning the channel's value
    /// range over the track.
    public let colorScale: ChannelColorScale

    /// The index in ``coordinates`` where each separately drawn run begins — one
    /// per selected lap, or a single `[0]` for the whole track; empty when there
    /// is nothing to draw. The view never strokes a segment *into* a run start,
    /// so two laps are never joined by a line across the gap between them.
    public let runStarts: [Int]

    /// Each run's position in the lap selection (parallel to ``runStarts``) — the
    /// slot ``PlotColor/selectionColor(at:)`` colours it by, so a lap is the same
    /// colour on the map as in every other panel. `[0]` for the whole track.
    public let runSlots: [Int]

    /// Each run's lap number as the user knows it (parallel to ``runStarts``), or
    /// `nil` when the whole track is shown or the caller gave no numbers.
    public let runLapNumbers: [Int?]

    /// The selected laps' time windows, or `nil` when the whole track is shown.
    private let windows: [ClosedRange<Double>]?

    /// Each run's time window (parallel to ``runStarts``); empty for the whole track.
    private let runWindows: [ClosedRange<Double>]

    /// The first run's distances rebased to start at `0` — the axis the sector
    /// marks are placed along. It is a prefix of the fixes (the first run starts
    /// at index 0), so an index into it is also an index into ``coordinates``.
    ///
    /// Selected laps overlap on the ground, so marking one lap marks them all;
    /// partitioning every lap's distance end to end would put a "sector" boundary
    /// a lap and a half round the circuit.
    ///
    /// Stored, not computed: the panel reads it on every cursor-driven render.
    public let sectorDistances: [Double]

    /// The length (metres) of the lap the sector marks partition — the first
    /// run's rebased extent, `0` for an empty map.
    public var lapDistance: Double { sectorDistances.last ?? 0 }

    /// - Parameters:
    ///   - track: the GPS fixes forming the racing line.
    ///   - colorSeries: the channel whose value colours the line, or `nil` for a
    ///     neutral line.
    ///   - laps: the selected laps' time windows, in selection order — only fixes
    ///     inside one are kept, each lap its own run (drawn in time order) — or
    ///     `nil` for the whole track.
    ///   - lapNumbers: the number of the lap each window belongs to (parallel to
    ///     `laps`), for the map's legend; missing entries read as unnumbered.
    ///   - low: the gradient colour at the channel minimum.
    ///   - high: the gradient colour at the channel maximum.
    public init(track: [GPSTrackPoint], colorSeries: ChannelSeries? = nil,
                laps: [ClosedRange<Double>]? = nil,
                lapNumbers: [Int] = [],
                low: PlotColor = TrackMapModel.defaultLow,
                high: PlotColor = TrackMapModel.defaultHigh) {
        let runs = Self.runs(of: track, in: laps)
        let kept = runs.flatMap(\.fixes)
        self.coordinates = kept.map(\.coordinate)
        self.distances = kept.map(\.distance)
        self.times = kept.map(\.time)
        self.windows = laps?.sorted { $0.lowerBound < $1.lowerBound }
        var starts: [Int] = []
        var offset = 0
        for run in runs {
            starts.append(offset)
            offset += run.fixes.count
        }
        self.runStarts = starts
        self.runSlots = runs.map(\.slot)
        self.runWindows = laps == nil ? [] : runs.map(\.window)
        self.runLapNumbers = runs.map { run in
            laps != nil && lapNumbers.indices.contains(run.slot) ? lapNumbers[run.slot] : nil
        }
        let firstRunEnd = starts.count > 1 ? starts[1] : distances.count
        let base = distances.first ?? 0
        self.sectorDistances = distances[..<firstRunEnd].map { $0 - base }

        guard let colorSeries, !colorSeries.xs.isEmpty else {
            self.channelValues = []
            self.colorScale = ChannelColorScale(domain: 0...1, low: low, high: high)
            return
        }
        // Interpolate the colour channel onto each fix's time (a fix falls between
        // the channel's own samples). A dropped fix (a non-finite time) can't be
        // read off the channel, so it maps to NaN — which `ChannelColorScale` pins
        // neutrally — while staying index-aligned with `coordinates`.
        let values = times.map { ValueAtCursor.value(at: $0, in: colorSeries).value ?? .nan }
        self.channelValues = values
        let finite = values.filter(\.isFinite)
        if let lower = finite.min(), let upper = finite.max() {
            self.colorScale = ChannelColorScale(domain: lower...upper, low: low, high: high)
        } else {
            self.colorScale = ChannelColorScale(domain: 0...1, low: low, high: high)
        }
    }

    /// The fix index nearest cursor time `time` (the marker position), or `nil` for
    /// an empty track (or a non-finite `time`). A linear nearest scan — like
    /// ``TrackPath/nearestIndex(to:in:)`` — rather than the binary ``hitTest``,
    /// because GPS fix times carry no monotonicity guarantee across the FFI (a
    /// dropped fix can leave a non-finite time); the scan skips those and never
    /// mis-indexes or traps. Ties resolve to the lower index.
    ///
    /// Scoped to laps, a time outside every selected lap has no marker: snapping
    /// it to the nearest selected lap would show the car where it was not.
    public func index(atTime time: Double) -> Int? {
        guard time.isFinite else { return nil }
        if let windows, !windows.contains(where: { $0.contains(time) }) { return nil }
        var bestIndex: Int?
        var bestDelta = Double.infinity
        for (offset, fixTime) in times.enumerated() where fixTime.isFinite {
            let delta = abs(fixTime - time)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = offset
            }
        }
        return bestIndex
    }

    /// The cursor time at fix `index` (a map hover / click drives the cursor), or
    /// `nil` when the index is out of range.
    public func time(atIndex index: Int) -> Double? {
        times.indices.contains(index) ? times[index] : nil
    }

    /// Where every selected lap was at the same time into the lap as the cursor —
    /// one marker per lap, so the gap between them on the map *is* the time gap
    /// between the laps at that moment. The cursor's own lap is flagged
    /// ``TrackMapMarker/isCursorLap``.
    ///
    /// Empty when `time` is outside every selected lap (the car was not in any of
    /// them then). A lap shorter than the offset has already finished: its marker
    /// sits at its last fix, flagged ``TrackMapMarker/isBeyondLap``. With the whole
    /// track shown there is one marker, at the fix nearest `time`.
    public func markers(atTime time: Double) -> [TrackMapMarker] {
        guard time.isFinite else { return [] }
        guard windows != nil else {
            return index(atTime: time).map {
                [TrackMapMarker(index: $0, slot: nil, lapNumber: nil, isCursorLap: true, isBeyondLap: false)]
            } ?? []
        }
        // On a boundary shared by two laps the cursor is at the *start* of the
        // later one — offset 0 — not the end of the earlier.
        guard let cursorRun = runWindows.indices
            .filter({ runWindows[$0].contains(time) })
            .max(by: { runWindows[$0].lowerBound < runWindows[$1].lowerBound }) else { return [] }
        let offset = time - runWindows[cursorRun].lowerBound
        return runWindows.indices.compactMap { run -> TrackMapMarker? in
            let window = runWindows[run]
            let target = window.lowerBound + offset
            guard let index = nearestIndex(to: min(target, window.upperBound), inRun: run) else { return nil }
            return TrackMapMarker(index: index, slot: runSlots[run], lapNumber: runLapNumbers[run],
                                  isCursorLap: run == cursorRun, isBeyondLap: target > window.upperBound)
        }
    }

    /// The fix in run `run` nearest `time`; a lap's run holds only finite times.
    private func nearestIndex(to time: Double, inRun run: Int) -> Int? {
        let start = runStarts[run]
        let end = run + 1 < runStarts.count ? runStarts[run + 1] : times.count
        return (start..<end).min { abs(times[$0] - time) < abs(times[$1] - time) }
    }

    /// One drawn run: its fixes, and — scoped to laps — the window it came from
    /// and that lap's position in the selection.
    private struct Run {
        let fixes: [GPSTrackPoint]
        let window: ClosedRange<Double>
        let slot: Int
    }

    /// The fixes to draw, grouped into runs: the whole track as one run, or one
    /// run per lap window in time order holding the finite-time fixes inside it.
    /// A window with no fixes contributes no run. Adjacent laps each keep their
    /// shared boundary fix, so each is drawn closed.
    private static func runs(of track: [GPSTrackPoint], in laps: [ClosedRange<Double>]?) -> [Run] {
        guard let laps else {
            return track.isEmpty ? [] : [Run(fixes: track, window: 0...0, slot: 0)]
        }
        return laps.indices
            .map { slot in
                let window = laps[slot]
                return Run(fixes: track.filter { $0.time.isFinite && window.contains($0.time) },
                           window: window, slot: slot)
            }
            .sorted { $0.window.lowerBound < $1.window.lowerBound }
            .filter { !$0.fixes.isEmpty }
    }

    /// The cool→hot default gradient endpoints (the shared palette's blue and
    /// orange) for colour-by-channel.
    public static let defaultLow = PlotColor.palette[0]
    public static let defaultHigh = PlotColor.palette[1]
}

/// One lap's position marker on the track map (see ``TrackMapModel/markers(atTime:)``).
public struct TrackMapMarker: Equatable, Sendable {
    /// The fix the marker sits on, an index into ``TrackMapModel/coordinates``.
    public let index: Int
    /// The lap's position in the selection — its colour — or `nil` for the whole
    /// track, which has no lap to colour it by.
    public let slot: Int?
    /// The lap's number, when known.
    public let lapNumber: Int?
    /// `true` for the lap the cursor is actually in.
    public let isCursorLap: Bool
    /// `true` when this lap had already finished at the cursor's offset.
    public let isBeyondLap: Bool
}
