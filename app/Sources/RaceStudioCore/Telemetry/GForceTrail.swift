import Foundation

/// One `(lateral, longitudinal)` acceleration sample — a point of the G-ball
/// trail (issue 9.9).
public struct GForcePoint: Equatable, Sendable {
    /// Session time (seconds) of the sample.
    public let time: Double
    /// Lateral acceleration (g), positive to the right.
    public let lateral: Double
    /// Longitudinal acceleration (g), positive under acceleration.
    public let longitudinal: Double

    public init(time: Double, lateral: Double, longitudinal: Double) {
        self.time = time
        self.lateral = lateral
        self.longitudinal = longitudinal
    }
}

/// The G-ball trail of one frame (issue 9.9): the logged G samples of the last
/// second up to the frame's time, oldest first, indexed from `0`.
///
/// It is a view into the timeline's own storage — sampling a frame copies
/// nothing. Its newest point is the last *logged* sample at or before the
/// frame's time, so it can trail the frame's interpolated ``TelemetryFrame/latG``
/// / ``TelemetryFrame/lonG`` (the ball itself) by up to one sample period.
public struct GForceTrail: RandomAccessCollection, Equatable, Sendable {
    private let points: ArraySlice<GForcePoint>

    init(_ points: ArraySlice<GForcePoint>) {
        self.points = points
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { points.count }

    public subscript(position: Int) -> GForcePoint {
        points[points.startIndex + position]
    }

    public static func == (lhs: GForceTrail, rhs: GForceTrail) -> Bool {
        lhs.points.elementsEqual(rhs.points)
    }
}

/// Every `(lateral, longitudinal)` G sample of a session paired on one time
/// axis — the store ``GForceTrail``s are cut from (issue 9.9).
struct GForceSamples: Sendable {
    /// How far back a trail reaches (seconds).
    static let duration = 1.0

    private let points: [GForcePoint]
    private let times: [Double]

    /// Pairs each lateral sample with the longitudinal value at its time; a
    /// sample with no longitudinal value there (a gap) is left out.
    init(lateral: TelemetrySeries?, longitudinal: TelemetrySeries?) {
        guard let lateral, let longitudinal else {
            self.points = []
            self.times = []
            return
        }
        var points: [GForcePoint] = []
        points.reserveCapacity(lateral.times.count)
        var hint = -1
        for (time, value) in zip(lateral.times, lateral.values) where value.isFinite {
            if let lon = longitudinal.value(at: time, hint: &hint) {
                points.append(GForcePoint(time: time, lateral: value, longitudinal: lon))
            }
        }
        self.points = points
        self.times = points.map(\.time)
    }

    /// The samples in `(t − duration, t]`, oldest first.
    func trail(at t: Double, end: inout Int, start: inout Int) -> GForceTrail {
        guard t.isFinite else { return GForceTrail(points[0..<0]) }
        let upper = lastIndex(atOrBefore: t, in: times, hint: &end) + 1
        let lower = lastIndex(atOrBefore: t - Self.duration, in: times, hint: &start) + 1
        return GForceTrail(lower < upper ? points[lower..<upper] : points[0..<0])
    }

    /// The bytes the samples retain.
    var byteCount: Int {
        points.count * MemoryLayout<GForcePoint>.stride + times.count * MemoryLayout<Double>.stride
    }
}
