import CoreGraphics
import Foundation

/// Where the kart is on the mini map at one instant (issue 9.9).
public struct TrackPositionReading: Equatable, Sendable {
    /// The position in the unit map frame, north up: on-circuit positions lie in
    /// `0…1` on both axes (a stray trail off the framed circuit may fall outside).
    public let point: CGPoint
    /// The direction of travel, degrees clockwise from north (`0..<360`), or
    /// `nil` when the kart has not moved yet.
    public let heading: Double?

    public init(point: CGPoint, heading: Double?) {
        self.point = point
        self.heading = heading
    }
}

/// The kart's position on the mini track map at any session time (issue 9.9).
///
/// The map frame is the one the library preview and the track map draw: the
/// best lap's fixes (``SessionPreview/bestLapCoordinates(_:track:)``) fitted
/// into the unit square by ``GeoProjection`` with ``GeoProjection/framingTrim``,
/// north up. Every fix is projected once, at build time; a read interpolates
/// the projected points (the projection is affine in latitude/longitude, so
/// that equals projecting the interpolated fix) and step-holds the heading of
/// the segment the kart is on. ``racingLine`` is the pre-projected best lap,
/// for drawing the static map.
public struct TrackPosition: Sendable {

    /// The projection into the unit map frame.
    public let projection: GeoProjection
    /// The best lap (or, with no valid lap, the whole track) projected into the
    /// unit frame — the line the mini map strokes.
    public let racingLine: [CGPoint]

    private let x: TelemetrySeries
    private let y: TelemetrySeries
    private let heading: TelemetrySeries

    /// - Parameters:
    ///   - track: the session's GPS fixes.
    ///   - laps: the session's laps, which pick the best lap to frame.
    ///   - maxGap: the GPS gap threshold (seconds); no position inside a longer gap.
    public init(track: [GPSTrackPoint], laps: [Lap], maxGap: Double = TelemetrySeries.defaultMaxGap) {
        let framed = SessionPreview.bestLapCoordinates(laps, track: track)
        let projection = GeoProjection.fit(to: framed, trimmingFraction: GeoProjection.framingTrim)
        self.projection = projection
        self.racingLine = framed.count >= 2 ? framed.map(projection.project) : []

        // Keep the fixes a search can use: finite, strictly increasing times.
        var times: [Double] = []
        var points: [CGPoint] = []
        times.reserveCapacity(track.count)
        points.reserveCapacity(track.count)
        for fix in track where fix.time.isFinite && fix.time > (times.last ?? -.infinity) {
            times.append(fix.time)
            points.append(projection.project(fix.coordinate))
        }
        self.x = TelemetrySeries(times: times, values: points.map { Double($0.x) }, maxGap: maxGap)
        self.y = TelemetrySeries(times: times, values: points.map { Double($0.y) }, maxGap: maxGap)
        self.heading = TelemetrySeries(times: times, values: Self.headings(points), mode: .stepHold, maxGap: maxGap)
    }

    /// Whether the session has no GPS fix to place the kart by.
    public var isEmpty: Bool { x.isEmpty }

    /// The kart's position at session time `t`, or `nil` outside the fixes or
    /// inside a GPS gap.
    public func reading(at t: Double) -> TrackPositionReading? {
        var hint = -1
        return reading(at: t, hint: &hint)
    }

    /// The position at `t`, reusing `hint` across a sweep (the three series share
    /// one time axis, so one hint serves them all).
    public func reading(at t: Double, hint: inout Int) -> TrackPositionReading? {
        guard let px = x.value(at: t, hint: &hint), let py = y.value(at: t, hint: &hint) else { return nil }
        return TrackPositionReading(point: CGPoint(x: px, y: py), heading: heading.value(at: t, hint: &hint))
    }

    // MARK: - Internals

    /// The heading of the segment leaving each point (the last point keeps the
    /// final segment's), degrees clockwise from north in the map frame — whose
    /// uniform, latitude-corrected scale preserves ground bearings. A segment of
    /// zero length (a stationary kart) inherits the heading before it, or the
    /// first real heading when the kart had not yet moved; `NaN` throughout
    /// when it never moves.
    private static func headings(_ points: [CGPoint]) -> [Double] {
        var headings = [Double](repeating: .nan, count: points.count)
        var lastKnown = Double.nan
        for index in points.indices {
            let next = index + 1 < points.count ? points[index + 1] : points[index]
            let dx = Double(next.x - points[index].x), dy = Double(next.y - points[index].y)
            if dx != 0 || dy != 0 {
                // Map y grows southwards, so north is −y.
                let degrees = atan2(dx, -dy) * 180 / .pi
                lastKnown = degrees < 0 ? degrees + 360 : degrees
            }
            headings[index] = lastKnown
        }
        // Back-fill the stationary start with the first real heading.
        if let first = headings.firstIndex(where: { !$0.isNaN }) {
            for index in 0..<first { headings[index] = headings[first] }
        }
        return headings
    }
}
