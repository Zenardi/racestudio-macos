import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for loading a `TelemetryTimeline` (issue 9.9): every needed channel is
/// read once through the data source, off the main actor, and the result honours
/// the laps, split timeline, reference and channel map it was asked for.
@Suite struct TelemetryTimelineLoadTests {

    /// A ``SessionDataSource`` that forwards to the fixture's fake and records,
    /// for every read, what was read and whether it ran on the main thread.
    private final class RecordingSource: SessionDataSource, @unchecked Sendable {
        private let inner: FakeSessionDataSource
        private let lock = NSLock()
        private var log: [(read: String, onMain: Bool)] = []

        init(_ inner: FakeSessionDataSource) { self.inner = inner }

        var reads: [String] { lock.withLock { log.map(\.read) } }
        var anyOnMain: Bool { lock.withLock { log.contains { $0.onMain } } }

        private func record(_ read: String) {
            let onMain = Thread.isMainThread
            lock.withLock { log.append((read, onMain)) }
        }

        func samples(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DataSample] {
            record("samples \(channelIndex)")
            return inner.samples(channelIndex: channelIndex, start: start, count: count)
        }
        func gpsTrack(start: UInt32, count: UInt32) -> [GPSTrackPoint] {
            record("gps")
            return inner.gpsTrack(start: start, count: count)
        }
        func deltaT(referenceLap: UInt32, comparisonLap: UInt32, start: Double, end: Double) throws -> [DeltaSample] {
            record("delta \(referenceLap)→\(comparisonLap)")
            return try inner.deltaT(referenceLap: referenceLap, comparisonLap: comparisonLap, start: start, end: end)
        }
        func statistics(channel: String, start: Double, end: Double) throws -> ChannelStats {
            try inner.statistics(channel: channel, start: start, end: end)
        }
        func samplesWithDistance(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DistanceSample] {
            inner.samplesWithDistance(channelIndex: channelIndex, start: start, count: count)
        }
        func segmentTimes(splits: UInt32) -> [LapSegments] { inner.segmentTimes(splits: splits) }
        func spectrum(channel: String, windowFunction: SpectrumWindowKind,
                      start: Double, end: Double) throws -> ChannelSpectrum {
            try inner.spectrum(channel: channel, windowFunction: windowFunction, start: start, end: end)
        }
        func detectTrack() -> DetectedTrackInfo? { inner.detectTrack() }
    }

    // MARK: - Reading once, off the main actor

    /// Given an analysis session on the main actor, when the timeline loads,
    /// then each bound channel, the GPS track and each lap's delta series are
    /// read exactly once — and none of it on the main thread.
    @Test @MainActor func test_load_reads_each_input_once_off_the_main_actor() async throws {
        let built = TelemetryFixture.make()
        let source = RecordingSource(built.source)
        let analysis = AnalysisSession(session: built.session, dataSource: source)

        let timeline = try await TelemetryTimeline.load(from: analysis, timeline: built.sectors)
        _ = (0..<600).map { timeline.frame(at: Double($0) / 10) }

        #expect(!source.anyOnMain, "no data-source read on the main thread")
        #expect(source.reads.sorted() == ["delta 1→0", "delta 1→2", "gps",
                                          "samples 0", "samples 1", "samples 2", "samples 3",
                                          "samples 4", "samples 5", "samples 6"],
                "speed, both G, rpm, gear, water temp and the logger delta; once each; no read while sampling")
    }

    /// The laps passed in replace the session's: a timeline loaded with only the
    /// first two laps knows nothing of the third.
    @Test @MainActor func test_load_uses_the_laps_it_is_given() async throws {
        let built = TelemetryFixture.make()
        let analysis = AnalysisSession(session: built.session, dataSource: built.source)

        let timeline = try await TelemetryTimeline.load(from: analysis, laps: Array(built.session.laps.prefix(2)))

        #expect(timeline.frame(at: 30).lap?.lap == LapID(1))
        #expect(timeline.frame(at: 50).lap == nil)
    }

    /// An explicit reference and delta source are honoured at load.
    @Test func test_load_honours_the_reference_and_delta_source() async throws {
        let built = TelemetryFixture.make()

        let timeline = try await TelemetryTimeline.load(
            session: built.session, source: built.source, reference: LapID(2),
            deltaSource: .logger(channel: "Best Run Diff"))

        #expect(timeline.deltaReference == LapID(2))
        #expect(timeline.deltaSource == .logger(channel: "Best Run Diff"))
    }

    /// A hand-edited channel map replaces the automatic one.
    @Test func test_load_honours_a_channel_map_override() async throws {
        let built = TelemetryFixture.make()
        let channels = built.session.channels
        let remapped = TelemetryChannelMap.resolve(channels: channels).overriding(.latG, with: channels[1])

        let timeline = try await TelemetryTimeline.load(session: built.session, source: built.source,
                                                        channelMap: remapped)

        #expect(timeline.channelMap == remapped)
        #expect(timeline.frame(at: 5).latG == 0.3, "lateral now reads the inline channel")
    }

    /// A cancelled load stops with `CancellationError` instead of finishing.
    @Test func test_a_cancelled_load_throws() async {
        let built = TelemetryFixture.make()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelemetryTimeline.load(session: built.session, source: built.source)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A session with no channels, laps or GPS still loads: every frame is empty.
    @Test func test_an_empty_session_loads_to_empty_frames() async throws {
        let session = Session(metadata: SessionFixture.make().metadata, channels: [], laps: [])

        let timeline = try await TelemetryTimeline.load(session: session, source: FakeSessionDataSource(banks: []))

        let frame = timeline.frame(at: 1)
        #expect(frame.speed == nil && frame.lap == nil && frame.delta == nil && frame.position == nil)
        #expect(timeline.timeRange == nil)
        #expect(timeline.deltaReference == nil)
    }

    // MARK: - Edge inputs

    /// A channel with no known rate keeps the default 0.5 s gap threshold; a
    /// logger delta channel already in seconds is not rescaled.
    @Test func test_rate_less_channels_and_second_deltas() async throws {
        let channels = [Channel(name: "RPM", unit: "rpm", sampleRateHz: 0, decimals: 0, sampleCount: 3),
                        Channel(name: "Ref Lap Diff", unit: "s", sampleRateHz: 1, decimals: 2, sampleCount: 2)]
        let banks = [[DataSample(time: 0, value: 0), DataSample(time: 0.4, value: 4), DataSample(time: 1.0, value: 10)],
                     [DataSample(time: 0, value: 0.25), DataSample(time: 2, value: 0.5)]]
        let session = Session(metadata: SessionFixture.make().metadata, channels: channels, laps: [])

        let timeline = try await TelemetryTimeline.load(session: session, source: FakeSessionDataSource(banks: banks),
                                                        deltaSource: .logger(channel: "Ref Lap Diff"))

        #expect(timeline.frame(at: 0.2).rpm == 2)
        #expect(timeline.frame(at: 0.7).rpm == nil, "0.6 s apart: a gap at the default threshold")
        #expect(timeline.frame(at: 1).delta == 0.25)
    }

    /// A delta the core cannot compute — it throws, or a lap index it cannot
    /// address — reads `nil` instead of failing the frame.
    @Test func test_an_unavailable_core_delta_reads_nil() async throws {
        let built = TelemetryFixture.make()
        let failing = FakeSessionDataSource(banks: [], gps: built.source.gpsTrack(start: 0, count: .max),
                                            deltaError: FakeSessionDataSource.UnknownChannel())

        let timeline = try await TelemetryTimeline.load(session: built.session, source: failing)
        let unaddressable = try await TelemetryTimeline.load(session: built.session, source: built.source)
            .withDeltaReference(LapID(-1))

        #expect(timeline.frame(at: 10).delta == nil)
        #expect(unaddressable.frame(at: 10).delta == nil)
        #expect(timeline.approximateByteCount > 0, "a lap known to have no series still accounts")
    }

    /// A map resolved against another listing never reads past this session's
    /// channels, and a logger channel this session lacks is skipped.
    @Test func test_a_foreign_channel_map_only_reads_this_sessions_channels() async throws {
        let built = TelemetryFixture.make(gpsOnly: true)
        let foreign = built.session.channels + [
            Channel(name: "RPM", unit: "rpm", sampleRateHz: 20, decimals: 0, sampleCount: 10),
            Channel(name: "Best Run Diff", unit: "ms", sampleRateHz: 1, decimals: 0, sampleCount: 10)]

        let timeline = try await TelemetryTimeline.load(
            session: built.session, source: built.source,
            channelMap: TelemetryChannelMap.resolve(channels: foreign))

        #expect(timeline.frame(at: 5).rpm == nil)
        #expect(timeline.frame(at: 5).speed != nil)
    }

    /// Prefetching a re-referenced timeline fetches every other lap's series
    /// against the new reference, so the export sweep never waits on the core.
    @Test func test_prefetching_a_new_reference_fetches_every_other_lap() async throws {
        let built = TelemetryFixture.make()
        let source = RecordingSource(built.source)
        let timeline = try await TelemetryTimeline.load(session: built.session, source: source)

        timeline.withDeltaReference(LapID(0)).prefetchDeltas()

        #expect(source.reads.filter { $0.hasPrefix("delta 0") }.sorted() == ["delta 0→1", "delta 0→2"])
    }
}
