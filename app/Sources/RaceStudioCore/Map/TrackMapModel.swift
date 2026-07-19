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

    /// The total length (metres) of the rendered track — the last fix's cumulative
    /// distance, `0` for an empty track. Named for the `SectorModel`/`TrackMapView`
    /// parameter it feeds; the sector marks partition this whole extent.
    ///
    /// The window's model renders the whole GPS track (every lap), so on a
    /// multi-lap session this is the session distance, not a single lap's — the
    /// sectors then partition the full trace. Per-lap scoping (and the GPS↔channel
    /// clock alignment it needs) is deferred to a later issue, consistent with
    /// 8.3's whole-session time-axis scrubbing.
    public var lapDistance: Double { distances.last ?? 0 }

    /// - Parameters:
    ///   - track: the GPS fixes forming the racing line.
    ///   - colorSeries: the channel whose value colours the line, or `nil` for a
    ///     neutral line.
    ///   - low: the gradient colour at the channel minimum.
    ///   - high: the gradient colour at the channel maximum.
    public init(track: [GPSTrackPoint], colorSeries: ChannelSeries? = nil,
                low: PlotColor = TrackMapModel.defaultLow,
                high: PlotColor = TrackMapModel.defaultHigh) {
        self.coordinates = track.map(\.coordinate)
        self.distances = track.map(\.distance)
        self.times = track.map(\.time)

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
    public func index(atTime time: Double) -> Int? {
        guard time.isFinite else { return nil }
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

    /// The cool→hot default gradient endpoints (the shared palette's blue and
    /// orange) for colour-by-channel.
    public static let defaultLow = PlotColor.palette[0]
    public static let defaultHigh = PlotColor.palette[1]
}
