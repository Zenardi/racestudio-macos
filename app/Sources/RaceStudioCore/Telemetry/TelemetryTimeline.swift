import Foundation

/// The single answer to "what was the kart doing at session time `t`?" (issue
/// 9.9) — shared by the in-app Video + Data HUD and the burned-in MP4 export.
///
/// Loaded once per session (``load(session:source:sectors:reference:deltaSource:channelMap:)``,
/// off the main actor) into contiguous per-role series, the lap clock, the live
/// delta, the projected track and the G trail; then sampled as a
/// ``TelemetryFrame``:
///
/// - ``frame(at:cursor:)`` — the export path: one ``SamplingCursor`` per reader
///   makes a forward sweep amortized O(1) per frame and allocation-free;
/// - ``frame(at:)`` — the random path (a seek): binary searches, O(log n).
///
/// Both give identical frames. The timeline is an immutable `Sendable` value
/// (its one mutable part, the lazily fetched delta curves, sits behind a lock),
/// so an export worker and the UI may sample it at the same time.
public struct TelemetryTimeline: Sendable {

    /// Which channel plays each role.
    public let channelMap: TelemetryChannelMap
    /// The lap timer.
    public let clock: LapClock
    /// The kart's position on the mini map, and the racing line to draw it on.
    public let position: TrackPosition
    /// Where the frame's delta comes from.
    public let deltaSource: DeltaSource

    private let roles: [TelemetrySeries?]
    private let liveDelta: LiveDelta
    private let loggerDeltas: [String: TelemetrySeries]
    private let loggerDelta: TelemetrySeries?
    private let gForce: GForceTrail

    /// - Parameters:
    ///   - channelMap: the role bindings the series were read through.
    ///   - series: each available role's series, already in the frame's units.
    ///   - clock: the lap timer.
    ///   - position: the track position.
    ///   - liveDelta: the computed delta against the reference lap.
    ///   - loggerDeltas: the logger's own delta channels by name, in seconds.
    ///   - deltaSource: which delta a frame reports.
    public init(channelMap: TelemetryChannelMap, series: [TelemetryRole: TelemetrySeries], clock: LapClock,
                position: TrackPosition, liveDelta: LiveDelta, loggerDeltas: [String: TelemetrySeries] = [:],
                deltaSource: DeltaSource = .computed) {
        self.init(channelMap: channelMap, roles: TelemetryRole.ordered.map { series[$0] }, clock: clock,
                  position: position, liveDelta: liveDelta, loggerDeltas: loggerDeltas, deltaSource: deltaSource,
                  gForce: GForceTrail(lateral: series[.latG], longitudinal: series[.lonG]))
    }

    /// The lap the computed delta compares against, or `nil` when there is none.
    public var deltaReference: LapID? { liveDelta.reference }

    /// The span the session's samples cover (every role and the GPS), or `nil`
    /// when it has none.
    public var timeRange: ClosedRange<Double>? {
        let ranges = roles.compactMap { $0?.timeRange } + [position.timeRange].compactMap { $0 }
        guard let lower = ranges.map(\.lowerBound).min(), let upper = ranges.map(\.upperBound).max() else {
            return nil
        }
        return lower...upper
    }

    // MARK: - Sampling

    /// The frame at session time `t` — the random-access read.
    public func frame(at t: Double) -> TelemetryFrame {
        var cursor = SamplingCursor()
        return frame(at: t, cursor: &cursor)
    }

    /// The frame at session time `t`, reusing `cursor` from the previous read —
    /// the sequential export path. Any cursor is safe; it only skips searches.
    public func frame(at t: Double, cursor: inout SamplingCursor) -> TelemetryFrame {
        var values = TelemetryRoleValues()
        for role in TelemetryRole.ordered {
            if let series = roles[role.slot] {
                values[role] = series.value(at: t, hint: &cursor.roles[role.slot])
            }
        }
        let lap = clock.reading(at: t, hint: &cursor.lap)
        let delta: Double?
        switch deltaSource {
        case .computed:
            delta = lap.flatMap { liveDelta.delta(at: t, lap: $0.lap, hints: &cursor.delta) }
        case .logger:
            delta = loggerDelta?.value(at: t, hint: &cursor.logger)
        }
        return TelemetryFrame(time: t, values: values, lap: lap, delta: delta,
                              position: position.reading(at: t, hint: &cursor.position),
                              gTrail: gForce.trail(at: t, end: &cursor.trailEnd, start: &cursor.trailStart))
    }

    // MARK: - Variants

    /// This timeline with the computed delta compared against `reference`
    /// instead (`nil` for none); its curves are fetched afresh, lazily. Start a
    /// new ``SamplingCursor`` for it.
    public func withDeltaReference(_ reference: LapID?) -> TelemetryTimeline {
        TelemetryTimeline(channelMap: channelMap, roles: roles, clock: clock, position: position,
                          liveDelta: liveDelta.referencing(reference), loggerDeltas: loggerDeltas,
                          deltaSource: deltaSource, gForce: gForce)
    }

    /// This timeline reporting its delta from `source` instead. A logger channel
    /// the session does not carry reads `nil`.
    public func withDeltaSource(_ source: DeltaSource) -> TelemetryTimeline {
        TelemetryTimeline(channelMap: channelMap, roles: roles, clock: clock, position: position,
                          liveDelta: liveDelta, loggerDeltas: loggerDeltas, deltaSource: source, gForce: gForce)
    }

    /// Fetch every lap's delta curve now, so a sweep never waits on the core.
    /// ``load(session:source:sectors:reference:deltaSource:channelMap:)`` already does.
    public func prefetchDeltas() {
        liveDelta.prefetch()
    }

    /// An estimate of the bytes the timeline retains for its samples (the
    /// series, the projected track, the odometer and the G trail).
    public var approximateByteCount: Int {
        roles.reduce(0) { $0 + ($1?.byteCount ?? 0) }
            + loggerDeltas.values.reduce(0) { $0 + $1.byteCount }
            + position.byteCount + liveDelta.byteCount + gForce.byteCount
    }

    // MARK: - Internals

    private init(channelMap: TelemetryChannelMap, roles: [TelemetrySeries?], clock: LapClock,
                 position: TrackPosition, liveDelta: LiveDelta, loggerDeltas: [String: TelemetrySeries],
                 deltaSource: DeltaSource, gForce: GForceTrail) {
        self.channelMap = channelMap
        self.roles = roles
        self.clock = clock
        self.position = position
        self.liveDelta = liveDelta
        self.loggerDeltas = loggerDeltas
        self.deltaSource = deltaSource
        if case .logger(let channel) = deltaSource {
            self.loggerDelta = loggerDeltas[channel]
        } else {
            self.loggerDelta = nil
        }
        self.gForce = gForce
    }
}

extension TelemetrySeries {
    /// The bytes the series' two arrays retain.
    var byteCount: Int { (times.count + values.count) * MemoryLayout<Double>.stride }
}
