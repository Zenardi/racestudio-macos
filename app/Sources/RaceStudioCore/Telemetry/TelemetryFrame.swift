import Foundation

/// One `(lateral, longitudinal)` acceleration sample — a point of the G-ball
/// trail (issue 9.9).
public struct GForcePoint: Equatable, Sendable {
    /// Session time (seconds) of the sample.
    public let time: Double
    /// Lateral acceleration (g).
    public let lateral: Double
    /// Longitudinal acceleration (g).
    public let longitudinal: Double

    public init(time: Double, lateral: Double, longitudinal: Double) {
        self.time = time
        self.lateral = lateral
        self.longitudinal = longitudinal
    }
}

/// What the kart was doing at one session instant (issue 9.9) — the value the
/// overlay renderer draws a video frame from, identical in the live HUD and the
/// burned-in export.
///
/// Values are in canonical units — speed km/h, rpm, G in g, temperatures °C,
/// times and the delta in seconds — so preview and export format them the same
/// way; display conversion is the renderer's job. Anything the session cannot
/// say at this instant (a missing channel, a sample gap, no lap, no GPS) is
/// `nil`, never zero.
public struct TelemetryFrame: Equatable, Sendable {
    /// The session time the frame was sampled at (seconds, the cursor's clock).
    public let time: Double
    private let values: TelemetryRoleValues
    /// The lap timer, or `nil` outside every valid lap.
    public let lap: LapClockReading?
    /// The live delta to the reference lap (seconds; negative = gaining), or
    /// `nil` when it cannot be computed here.
    public let delta: Double?
    /// The kart's place on the mini map, or `nil` without a GPS fix.
    public let position: TrackPositionReading?
    /// The last second of G samples up to `t`, oldest first — the G-ball trail.
    /// A view into the timeline's own storage (no copy).
    public let gTrail: ArraySlice<GForcePoint>

    init(time: Double, values: TelemetryRoleValues, lap: LapClockReading?, delta: Double?,
         position: TrackPositionReading?, gTrail: ArraySlice<GForcePoint>) {
        self.time = time
        self.values = values
        self.lap = lap
        self.delta = delta
        self.position = position
        self.gTrail = gTrail
    }

    /// The value of `role` (in its binding's unit), or `nil`.
    public subscript(role: TelemetryRole) -> Double? {
        values[role]
    }

    /// Speed (km/h).
    public var speed: Double? { self[.speed] }
    /// Engine speed (rpm).
    public var rpm: Double? { self[.rpm] }
    /// Gear, step-held (as logged).
    public var gear: Double? { self[.gear] }
    /// Throttle, in its channel's unit.
    public var throttle: Double? { self[.throttle] }
    /// Brake, in its channel's unit.
    public var brake: Double? { self[.brake] }
    /// Lateral acceleration (g).
    public var latG: Double? { self[.latG] }
    /// Longitudinal acceleration (g).
    public var lonG: Double? { self[.lonG] }
    /// Water temperature (°C).
    public var waterTemp: Double? { self[.waterTemp] }
    /// Exhaust temperature (°C).
    public var exhaustTemp: Double? { self[.exhaustTemp] }
}

/// One value per role, stored inline so a frame carries no heap allocation.
struct TelemetryRoleValues: Equatable, Sendable {
    private var speed, rpm, gear, throttle, brake, latG, lonG, waterTemp, exhaustTemp: Double?

    subscript(role: TelemetryRole) -> Double? {
        get {
            switch role {
            case .speed: return speed
            case .rpm: return rpm
            case .gear: return gear
            case .throttle: return throttle
            case .brake: return brake
            case .latG: return latG
            case .lonG: return lonG
            case .waterTemp: return waterTemp
            case .exhaustTemp: return exhaustTemp
            }
        }
        set {
            switch role {
            case .speed: speed = newValue
            case .rpm: rpm = newValue
            case .gear: gear = newValue
            case .throttle: throttle = newValue
            case .brake: brake = newValue
            case .latG: latG = newValue
            case .lonG: lonG = newValue
            case .waterTemp: waterTemp = newValue
            case .exhaustTemp: exhaustTemp = newValue
            }
        }
    }
}

/// Search state carried across a sweep of ``TelemetryTimeline/frame(at:cursor:)``
/// (issue 9.9) — one per reader (the HUD, each export worker). It only speeds
/// the reads up: any cursor, fresh or stale, gives the same frames.
public struct SamplingCursor: Sendable {
    var roles = [Int](repeating: -1, count: TelemetryRole.ordered.count)
    var lap = -1
    var position = -1
    var logger = -1
    var trailEnd = -1
    var trailStart = -1
    var delta = LiveDelta.Hints()

    public init() {}
}

/// The `(lateral, longitudinal)` G samples paired on one time axis, read as a
/// trailing window for the G-ball (issue 9.9).
struct GForceTrail: Sendable {
    /// How far back the trail reaches (seconds).
    static let duration = 1.0

    let points: [GForcePoint]
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
    func trail(at t: Double, end: inout Int, start: inout Int) -> ArraySlice<GForcePoint> {
        guard t.isFinite else { return points[0..<0] }
        let upper = lastIndex(atOrBefore: t, in: times, hint: &end) + 1
        let lower = lastIndex(atOrBefore: t - Self.duration, in: times, hint: &start) + 1
        return lower < upper ? points[lower..<upper] : points[0..<0]
    }

    /// The bytes the trail retains.
    var byteCount: Int {
        points.count * MemoryLayout<GForcePoint>.stride + times.count * MemoryLayout<Double>.stride
    }
}
