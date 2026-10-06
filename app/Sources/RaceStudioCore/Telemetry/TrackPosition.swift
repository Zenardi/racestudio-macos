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
/// that equals projecting the interpolated fix) and step-holds the heading
/// computed for the fix before it. ``racingLine`` is the pre-projected best lap,
/// for drawing the static map.
public struct TrackPosition: Sendable {

    /// How far (metres) the kart must move before its direction counts — GPS
    /// jitter on a parked kart stays well inside it.
    static let headingMinimumTravel = 1.0
    /// How far ahead (seconds) a fix looks for that much travel before it holds
    /// the previous heading instead.
    static let headingLookahead = 2.0
    /// Ground metres per degree of latitude (the projection's raw unit).
    private static let metresPerDegree = 111_320.0

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
    ///   - maxGap: the GPS gap threshold (seconds); no position inside a longer
    ///     gap. `nil` (the default) derives it from the fixes' own spacing
    ///     (``TelemetrySeries/gapThreshold(forTimes:)``), so a 1 Hz GPS is not
    ///     one long gap.
    public init(track: [GPSTrackPoint], laps: [Lap], maxGap: Double? = nil) {
        let framed = SessionPreview.bestLapCoordinates(laps, track: track)
        let projection = GeoProjection.fit(to: framed, trimmingFraction: GeoProjection.framingTrim)
        self.projection = projection
        self.racingLine = framed.count >= 2 ? framed.map(projection.project) : []

        // Keep the fixes a search can use, by the same rule every series uses.
        let kept = TelemetrySeries.searchableIndices(track.map(\.time), count: track.count)
        let times = kept.map { track[$0].time }
        let points = kept.map { projection.project(track[$0].coordinate) }
        let gap = maxGap ?? TelemetrySeries.gapThreshold(forTimes: times)
        let minimumTravel = Self.headingMinimumTravel / Self.metresPerDegree * projection.scale
        self.x = TelemetrySeries(times: times, values: points.map { Double($0.x) }, maxGap: gap)
        self.y = TelemetrySeries(times: times, values: points.map { Double($0.y) }, maxGap: gap)
        self.heading = TelemetrySeries(times: times, values: Self.headings(points, times: times,
                                                                           minimumTravel: minimumTravel),
                                       mode: .stepHold, maxGap: gap)
    }

    /// Whether the session has no GPS fix to place the kart by.
    public var isEmpty: Bool { x.isEmpty }

    /// The span the fixes cover, or `nil` without GPS.
    public var timeRange: ClosedRange<Double>? { x.timeRange }

    /// The bytes the projected track retains (the three series share one time
    /// axis, counted once).
    var byteCount: Int {
        (x.times.count + x.values.count + y.values.count + heading.values.count + racingLine.count * 2)
            * MemoryLayout<Double>.stride
    }

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

    /// The heading at each point: towards the first later point more than
    /// `minimumTravel` (map units) away within ``headingLookahead`` seconds, in
    /// degrees clockwise from north in the map frame — whose uniform,
    /// latitude-corrected scale preserves ground bearings. A point with no such
    /// travel ahead (a parked kart's jitter, the end of the track) holds the
    /// heading before it; a stationary start takes the first real heading; `NaN`
    /// throughout when the kart never moves.
    private static func headings(_ points: [CGPoint], times: [Double], minimumTravel: Double) -> [Double] {
        var headings = [Double](repeating: .nan, count: points.count)
        var lastKnown = Double.nan
        for index in points.indices {
            var ahead = index + 1
            while ahead < points.count, times[ahead] - times[index] <= headingLookahead {
                let dx = Double(points[ahead].x - points[index].x), dy = Double(points[ahead].y - points[index].y)
                if (dx * dx + dy * dy).squareRoot() > minimumTravel {
                    // Map y grows southwards, so north is −y.
                    let degrees = atan2(dx, -dy) * 180 / .pi
                    lastKnown = degrees < 0 ? degrees + 360 : degrees
                    break
                }
                ahead += 1
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
