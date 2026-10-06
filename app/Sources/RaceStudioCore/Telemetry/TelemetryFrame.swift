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
    /// The session channels the timeline was asked to sample by name (issue
    /// 9.11), beside the roles — empty unless it was.
    private let channels: NamedChannelValues

    /// A frame built by hand — previews and renderer snapshot tests.
    /// - Parameters:
    ///   - time: the session time it stands for.
    ///   - values: the roles that have a value (in their reported units); every
    ///     other role is `nil`.
    ///   - lap: the lap timer reading.
    ///   - delta: the live delta (seconds).
    ///   - position: the place on the mini map.
    ///   - gTrail: the G-ball trail, oldest first.
    ///   - channels: session channels by name (``value(ofChannel:)``), in their
    ///     own units.
    public init(time: Double, values: [TelemetryRole: Double], lap: LapClockReading? = nil, delta: Double? = nil,
                position: TrackPositionReading? = nil, gTrail: [GForcePoint] = [],
                channels: [String: Double] = [:]) {
        var roles = PerRole<Double?>(repeating: nil)
        for (role, value) in values { roles[role] = value }
        self.init(time: time, roleValues: roles, lap: lap, delta: delta, position: position,
                  gTrail: GForceTrail(ArraySlice(gTrail)), channels: NamedChannelValues(channels))
    }

    init(time: Double, roleValues: PerRole<Double?>, lap: LapClockReading?, delta: Double?,
         position: TrackPositionReading?, gTrail: GForceTrail, channels: NamedChannelValues = .none) {
        self.time = time
        self.values = roleValues
        self.lap = lap
        self.delta = delta
        self.position = position
        self.gTrail = gTrail
        self.channels = channels
    }

    /// The value of the session channel called `name` — matched like the
    /// channel map, ignoring case and surrounding spaces — in its own unit, or
    /// `nil` in a gap or when the timeline was not loaded with that channel
    /// (``TelemetryTimeline/load(session:source:sectors:reference:deltaSource:channelMap:channels:)``).
    public func value(ofChannel name: String) -> Double? {
        channels.value(forKey: TelemetryChannelMap.key(for: name))
    }

    /// As ``value(ofChannel:)``, for a name already reduced to its matching key
    /// (``TelemetryChannelMap/key(for:)``) — the per-frame path.
    func value(ofChannelKey key: String) -> Double? {
        channels.value(forKey: key)
    }

    /// The value of `role` (in its binding's unit), or `nil`.
    public subscript(role: TelemetryRole) -> Double? {
        values[role]
    }

    /// Whether `other` shows exactly what this frame shows — every value, the
    /// lap, the delta, the position, the G trail and the named channels —
    /// whatever instant each was sampled at (issue 9.12). The live HUD publishes
    /// a new frame only when this is `false`.
    public func hasSameReadings(as other: TelemetryFrame) -> Bool {
        values == other.values && lap == other.lap && delta == other.delta && position == other.position
            && gTrail == other.gTrail && channels == other.channels
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
    /// One hint per channel sampled by name; empty (no allocation) without any.
    var channels: [Int] = []

    public init() {}
}
