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

    /// The selected laps' time windows, or `nil` when the whole track is shown.
    private let windows: [ClosedRange<Double>]?

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
    ///   - laps: the selected laps' time windows (any order) — only fixes inside
    ///     one are kept, each lap its own run — or `nil` for the whole track.
    ///   - low: the gradient colour at the channel minimum.
    ///   - high: the gradient colour at the channel maximum.
    public init(track: [GPSTrackPoint], colorSeries: ChannelSeries? = nil,
                laps: [ClosedRange<Double>]? = nil,
                low: PlotColor = TrackMapModel.defaultLow,
                high: PlotColor = TrackMapModel.defaultHigh) {
        let runs = Self.runs(of: track, in: laps)
        let kept = runs.flatMap { $0 }
        self.coordinates = kept.map(\.coordinate)
        self.distances = kept.map(\.distance)
        self.times = kept.map(\.time)
        self.windows = laps?.sorted { $0.lowerBound < $1.lowerBound }
        var starts: [Int] = []
        var offset = 0
        for run in runs {
            starts.append(offset)
            offset += run.count
        }
        self.runStarts = starts
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

    /// The fixes to draw, grouped into runs: the whole track as one run, or one
    /// run per lap window in time order holding the finite-time fixes inside it.
    /// A window with no fixes contributes no run. Adjacent laps each keep their
    /// shared boundary fix, so each is drawn closed.
    private static func runs(of track: [GPSTrackPoint],
                             in laps: [ClosedRange<Double>]?) -> [[GPSTrackPoint]] {
        guard let laps else { return track.isEmpty ? [] : [track] }
        return laps.sorted { $0.lowerBound < $1.lowerBound }
            .map { window in track.filter { $0.time.isFinite && window.contains($0.time) } }
            .filter { !$0.isEmpty }
    }

    /// The cool→hot default gradient endpoints (the shared palette's blue and
    /// orange) for colour-by-channel.
    public static let defaultLow = PlotColor.palette[0]
    public static let defaultHigh = PlotColor.palette[1]
}
