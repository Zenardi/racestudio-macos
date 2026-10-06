import Foundation

/// What the kart was doing at one session instant (issue 9.9) — the value the
/// overlay renderer draws a video frame from, identical in the live HUD and the
/// burned-in export.
///
/// Speed (km/h), rpm, G (g) and temperatures (°C) are in canonical units, and
/// times and the delta in seconds, so preview and export format them the same
/// way; display conversion is the renderer's job. Gear and the pedals — and any
/// role hand-remapped to a channel in a unit the role does not recognise — are
/// passed through in their channel's unit (``TelemetryChannelBinding/unit``).
/// Anything the session cannot say at this instant (a missing channel, a
/// sample gap, no lap, no GPS) is `nil`, never zero.
public struct TelemetryFrame: Equatable, Sendable {
    /// The session time the frame was sampled at (seconds, the cursor's clock).
    public let time: Double
    private let values: PerRole<Double?>
    /// The lap timer, or `nil` outside every valid lap.
    public let lap: LapClockReading?
    /// The live delta to the reference lap (seconds; negative = gaining), or
    /// `nil` when it cannot be computed here.
    public let delta: Double?
    /// The kart's place on the mini map, or `nil` without a GPS fix.
    public let position: TrackPositionReading?
    /// The last second of G samples up to `t`, oldest first — the G-ball trail.
    public let gTrail: GForceTrail

    /// A frame built by hand — previews and renderer snapshot tests.
    /// - Parameters:
    ///   - time: the session time it stands for.
    ///   - values: the roles that have a value (in their reported units); every
    ///     other role is `nil`.
    ///   - lap: the lap timer reading.
    ///   - delta: the live delta (seconds).
    ///   - position: the place on the mini map.
    ///   - gTrail: the G-ball trail, oldest first.
    public init(time: Double, values: [TelemetryRole: Double], lap: LapClockReading? = nil, delta: Double? = nil,
                position: TrackPositionReading? = nil, gTrail: [GForcePoint] = []) {
        var roles = PerRole<Double?>(repeating: nil)
        for (role, value) in values { roles[role] = value }
        self.init(time: time, roleValues: roles, lap: lap, delta: delta, position: position,
                  gTrail: GForceTrail(ArraySlice(gTrail)))
    }

    init(time: Double, roleValues: PerRole<Double?>, lap: LapClockReading?, delta: Double?,
         position: TrackPositionReading?, gTrail: GForceTrail) {
        self.time = time
        self.values = roleValues
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
    /// Lateral acceleration (g), positive to the right.
    public var latG: Double? { self[.latG] }
    /// Longitudinal acceleration (g), positive under acceleration.
    public var lonG: Double? { self[.lonG] }
    /// Water temperature (°C).
    public var waterTemp: Double? { self[.waterTemp] }
    /// Exhaust temperature (°C).
    public var exhaustTemp: Double? { self[.exhaustTemp] }
}

/// One `Value` per ``TelemetryRole``, stored inline — no heap allocation, so a
/// frame's values and a cursor's hints cost nothing to create.
struct PerRole<Value: Equatable & Sendable>: Equatable, Sendable {
    private var speed, rpm, gear, throttle, brake, latG, lonG, waterTemp, exhaustTemp: Value

    init(repeating value: Value) {
        (speed, rpm, gear, throttle, brake) = (value, value, value, value, value)
        (latG, lonG, waterTemp, exhaustTemp) = (value, value, value, value)
    }

    subscript(role: TelemetryRole) -> Value {
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
/// the reads up: any cursor, fresh or stale, gives the same frames. Stored
/// inline, so creating one allocates nothing.
public struct SamplingCursor: Sendable {
    var roles = PerRole<Int>(repeating: -1)
    var lap = -1
    var position = -1
    var logger = -1
    var trailEnd = -1
    var trailStart = -1
    var delta = LiveDelta.Hints()

    public init() {}
}
