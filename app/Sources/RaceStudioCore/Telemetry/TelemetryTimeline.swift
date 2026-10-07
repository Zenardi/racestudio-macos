import Foundation

/// The single answer to "what was the kart doing at session time `t`?" (issue
/// 9.9) — shared by the in-app Video + Data HUD and the burned-in MP4 export.
///
/// Loaded once per session (``load(session:source:sectors:reference:deltaSource:channelMap:channels:)``,
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
    private let gForce: GForceSamples
    private let named: NamedChannelSeries

    /// - Parameters:
    ///   - channelMap: the role bindings the series were read through.
    ///   - series: each available role's series, already in the frame's units.
    ///   - clock: the lap timer.
    ///   - position: the track position.
    ///   - liveDelta: the computed delta against the reference lap.
    ///   - loggerDeltas: the logger's own delta channels by name, in seconds.
    ///   - deltaSource: which delta a frame reports.
    ///   - channels: session channels to sample by name (issue 9.11), in
    ///     their own units — what ``TelemetryFrame/value(ofChannel:)`` reads.
    public init(channelMap: TelemetryChannelMap, series: [TelemetryRole: TelemetrySeries], clock: LapClock,
                position: TrackPosition, liveDelta: LiveDelta, loggerDeltas: [String: TelemetrySeries] = [:],
                deltaSource: DeltaSource = .computed, channels: [String: TelemetrySeries] = [:]) {
        self.init(channelMap: channelMap, roles: TelemetryRole.ordered.map { series[$0] }, clock: clock,
                  position: position, liveDelta: liveDelta, loggerDeltas: loggerDeltas, deltaSource: deltaSource,
                  gForce: GForceSamples(lateral: series[.latG], longitudinal: series[.lonG]),
                  named: NamedChannelSeries(channels))
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
        var values = PerRole<Double?>(repeating: nil)
        for role in TelemetryRole.ordered {
            // Read through the optional in place: no copy of the series.
            values[role] = roles[role.slot]?.value(at: t, hint: &cursor.roles[role])
        }
        let lap = clock.reading(at: t, hint: &cursor.lap)
        let delta: Double?
        switch deltaSource {
        case .computed:
            delta = lap.flatMap { liveDelta.delta(at: t, lap: $0.lap, hints: &cursor.delta) }
        case .logger:
            delta = loggerDelta?.value(at: t, hint: &cursor.logger)
        }
        return TelemetryFrame(time: t, roleValues: values, lap: lap, delta: delta,
                              position: position.reading(at: t, hint: &cursor.position),
                              gTrail: gForce.trail(at: t, end: &cursor.trailEnd, start: &cursor.trailStart),
                              channels: named.values(at: t, hints: &cursor.channels))
    }

    // MARK: - Variants

    /// This timeline with the computed delta compared against `reference`
    /// instead (`nil` for none). Its curves are fetched afresh and **lazily**: the
    /// first frame of each lap fetches that lap's series from the core,
    /// synchronously, on the caller's thread. From the main actor use
    /// ``prefetchingDeltaReference(_:)`` instead. An overlay export
    /// (``OverlayVideoExporter``) prefetches the deltas itself before its first
    /// frame, so either form can be handed to it.
    public func withDeltaReference(_ reference: LapID?) -> TelemetryTimeline {
        TelemetryTimeline(channelMap: channelMap, roles: roles, clock: clock, position: position,
                          liveDelta: liveDelta.referencing(reference), loggerDeltas: loggerDeltas,
                          deltaSource: deltaSource, gForce: gForce, named: named)
    }

    /// This timeline reporting its delta from `source` instead. A logger channel
    /// the session does not carry reads `nil`.
    public func withDeltaSource(_ source: DeltaSource) -> TelemetryTimeline {
        TelemetryTimeline(channelMap: channelMap, roles: roles, clock: clock, position: position,
                          liveDelta: liveDelta, loggerDeltas: loggerDeltas, deltaSource: source, gForce: gForce,
                          named: named)
    }

    /// This timeline compared against `reference`, with every lap's delta series
    /// already fetched — off the main actor (a `nonisolated` `async` function) —
    /// so no frame read afterwards waits on the core.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public func prefetchingDeltaReference(_ reference: LapID?) async throws -> TelemetryTimeline {
        let timeline = withDeltaReference(reference)
        try await timeline.prefetchDeltas()
        return timeline
    }

    /// Fetch every lap's delta series now, off the main actor, so a sweep never
    /// waits on the core. ``load(session:source:sectors:reference:deltaSource:channelMap:channels:)``
    /// already does. Readers that race a cold cache may each fetch the same lap
    /// once; the fetch is idempotent, so prefetching is what avoids the waste.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public func prefetchDeltas() async throws {
        try liveDelta.prefetch()
    }

    /// An estimate of the bytes the timeline retains for its samples (the
    /// series, the projected track, the odometer, the G trail and the channels
    /// sampled by name).
    public var approximateByteCount: Int {
        roles.reduce(0) { $0 + ($1?.byteCount ?? 0) }
            + loggerDeltas.values.reduce(0) { $0 + $1.byteCount }
            + position.byteCount + liveDelta.byteCount + gForce.byteCount + named.byteCount
    }

    // MARK: - Internals

    private init(channelMap: TelemetryChannelMap, roles: [TelemetrySeries?], clock: LapClock,
                 position: TrackPosition, liveDelta: LiveDelta, loggerDeltas: [String: TelemetrySeries],
                 deltaSource: DeltaSource, gForce: GForceSamples, named: NamedChannelSeries) {
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
        self.named = named
    }
}

extension TelemetrySeries {
    /// The bytes the series' two arrays retain.
    var byteCount: Int { (times.count + values.count) * MemoryLayout<Double>.stride }
}
