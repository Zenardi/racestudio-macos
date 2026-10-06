import Foundation

extension TelemetryTimeline {

    /// Load the timeline of a session: every bound role's channel, the logger's
    /// delta channels, the GPS track and every lap's delta-t series are read
    /// **once** through `source`, then assembled. A `nonisolated` `async`
    /// function, so a caller on the main actor awaits it while the reads run
    /// off it; cancellation is checked between reads.
    ///
    /// - Parameters:
    ///   - session: the decoded session (channels and laps).
    ///   - source: the session's data source.
    ///   - sectors: the split timeline naming each lap's sectors.
    ///   - reference: the lap the live delta compares against; `nil` for the
    ///     session's best lap.
    ///   - deltaSource: which delta the frames report.
    ///   - channelMap: a hand-edited role map; `nil` resolves one automatically.
    ///   - channels: session channels to sample by name as well (issue 9.11) —
    ///     an overlay's channel readouts (``OverlayLayout/sessionChannelNames``),
    ///     in their own units, interpolated linearly between samples like every
    ///     role but gear. A name the session lacks is skipped and reads `nil`.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public static func load(session: Session, source: any SessionDataSource,
                            sectors: LapSectorTimeline = .empty, reference: LapID? = nil,
                            deltaSource: DeltaSource = .computed,
                            channelMap: TelemetryChannelMap? = nil,
                            channels: [String] = []) async throws -> TelemetryTimeline {
        try Task.checkCancellation()
        let map = channelMap ?? TelemetryChannelMap.resolve(channels: session.channels)
        var series: [TelemetryRole: TelemetrySeries] = [:]
        for role in TelemetryRole.ordered {
            guard let binding = map.binding(for: role) else { continue }
            try Task.checkCancellation()
            series[role] = read(binding.channelIndex, of: session, from: source, conversion: binding.conversion,
                                mode: role.interpolation)
        }
        var loggerDeltas: [String: TelemetrySeries] = [:]
        for name in map.loggerDeltaChannels {
            guard let index = session.channels.firstIndex(where: { $0.name == name }) else { continue }
            try Task.checkCancellation()
            let unit = session.channels[index].unit
            loggerDeltas[name] = read(index, of: session, from: source,
                                      conversion: TimecodeFormatter.isTimeUnit(unit) ? UnitConversion(scale: 0.001)
                                                                                      : .identity,
                                      mode: .stepHold, maxGap: .infinity)
        }
        var named: [String: TelemetrySeries] = [:]
        for name in channels {
            guard let index = map.channelIndex(named: name), named[session.channels[index].name] == nil else {
                continue
            }
            try Task.checkCancellation()
            named[session.channels[index].name] = read(index, of: session, from: source, conversion: .identity,
                                                       mode: .linear)
        }
        try Task.checkCancellation()
        let track = source.gpsTrack(start: 0, count: .max)
        let clock = LapClock(laps: session.laps, sectors: sectors)
        let fixTimes = track.map(\.time)
        let odometer = TelemetrySeries(times: fixTimes, values: track.map(\.distance),
                                       maxGap: TelemetrySeries.gapThreshold(forTimes: fixTimes))
        let liveDelta = LiveDelta(reference: reference ?? clock.best?.lap, laps: session.laps, distance: odometer,
                                  provider: deltaProvider(source))
        try liveDelta.prefetch()
        return TelemetryTimeline(channelMap: map, series: series, clock: clock,
                                 position: TrackPosition(track: track, laps: session.laps), liveDelta: liveDelta,
                                 loggerDeltas: loggerDeltas, deltaSource: deltaSource, channels: named)
    }

    /// Load the timeline of the session `analysis` serves — the UI entry point.
    /// The reads run off the main actor (see
    /// ``load(session:source:sectors:reference:deltaSource:channelMap:channels:)``).
    ///
    /// - Parameters:
    ///   - analysis: the loaded session's analysis pump.
    ///   - laps: the laps to time against; `nil` for the session's own.
    ///   - timeline: the split timeline naming each lap's sectors.
    ///   - reference: the live delta's reference lap; `nil` for the best lap.
    ///   - deltaSource: which delta the frames report.
    ///   - channelMap: a hand-edited role map; `nil` resolves one automatically.
    ///   - channels: session channels to sample by name as well.
    @MainActor
    public static func load(from analysis: AnalysisSession, laps: [Lap]? = nil,
                            timeline: LapSectorTimeline = .empty, reference: LapID? = nil,
                            deltaSource: DeltaSource = .computed,
                            channelMap: TelemetryChannelMap? = nil,
                            channels: [String] = []) async throws -> TelemetryTimeline {
        let session = analysis.session
        let timed = laps.map { Session(metadata: session.metadata, channels: session.channels, laps: $0) } ?? session
        return try await load(session: timed, source: analysis.dataSource, sectors: timeline,
                              reference: reference, deltaSource: deltaSource, channelMap: channelMap,
                              channels: channels)
    }

    // MARK: - Internals

    /// The whole channel at `index`, converted, as a series. The gap threshold
    /// scales with the channel's rate — two sample periods, never under the
    /// default — so a 1 Hz channel's normal cadence is not mistaken for a gap.
    private static func read(_ index: Int, of session: Session, from source: any SessionDataSource,
                             conversion: UnitConversion, mode: InterpolationMode,
                             maxGap: Double? = nil) -> TelemetrySeries? {
        guard session.channels.indices.contains(index), let channelIndex = UInt32(exactly: index) else { return nil }
        let channel = session.channels[index]
        let samples = source.samples(channelIndex: channelIndex, start: 0, count: channel.sampleCount)
        let rate = channel.sampleRateHz
        let gap = maxGap ?? TelemetrySeries.gapThreshold(sampleInterval: rate > 0 && rate.isFinite ? 1 / rate : 0)
        return TelemetrySeries(times: samples.map(\.time), values: samples.map { conversion.apply($0.value) },
                               mode: mode, maxGap: gap)
    }

    /// The core's delta-t series for a `(reference, lap)` pair over the whole
    /// lap, or `[]` when the core cannot compute it (the delta then reads `nil`).
    private static func deltaProvider(_ source: any SessionDataSource) -> LiveDelta.Provider {
        { reference, lap in
            guard let referenceIndex = UInt32(exactly: reference.index),
                  let lapIndex = UInt32(exactly: lap.index) else { return [] }
            return (try? source.deltaT(referenceLap: referenceIndex, comparisonLap: lapIndex,
                                       start: -.infinity, end: .infinity)) ?? []
        }
    }
}
