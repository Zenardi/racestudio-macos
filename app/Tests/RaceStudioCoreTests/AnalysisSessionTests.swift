import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisSession` (issue 8.1) — the `@MainActor` data pump that
/// retains a loaded session and vends windowed ``ChannelTrace`` / ``ChannelSeries``
/// / ``ChannelStats`` behind the ``SessionDataSource`` seam.
///
/// Every case drives a ``FakeSessionDataSource`` so the windowing/clamping logic
/// is covered **without the xcframework**; the FFI adapter is exercised
/// separately in `FFISessionDataSourceTests` against the real `.xrk`.
@Suite struct AnalysisSessionTests {

    // MARK: - Builders (no logic — fixed, index-derived data)

    private func channel(_ name: String, count: UInt32) -> Channel {
        Channel(name: name, unit: "", sampleRateHz: 10, decimals: 0, sampleCount: count)
    }

    private func session(_ channels: [Channel]) -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: channels, laps: [])
    }

    /// A bank of `count` samples where sample `i` is `(time: i, value: 2·i)` — so
    /// a windowed read's contents are trivially predictable from its indices.
    private func bank(_ count: Int) -> [DataSample] {
        (0..<count).map { DataSample(time: Double($0), value: Double($0) * 2) }
    }

    private var anyURL: URL { URL(fileURLWithPath: "/tmp/ignored.xrk") }

    // MARK: - trace: full / windowed / clamped

    @MainActor @Test func test_trace_reads_full_channel_over_the_all_window() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: .all)

        #expect(trace.name == "Speed")
        #expect(trace.samples.count == 10)
        #expect(trace.samples.first == PlotSample(time: 0, distance: 0, value: 0))
        #expect(trace.samples.last == PlotSample(time: 9, distance: 0, value: 18))
        #expect(source.lastRequest?.start == 0)
        #expect(source.lastRequest?.count == 10)
    }

    @MainActor @Test func test_trace_windowed_read_returns_only_the_requested_slice() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: SampleWindow(start: 3, count: 4))

        #expect(trace.samples.count == 4)
        #expect(trace.samples.first == PlotSample(time: 3, distance: 0, value: 6))
        #expect(trace.samples.last == PlotSample(time: 6, distance: 0, value: 12))
        #expect(source.lastRequest?.start == 3)
        #expect(source.lastRequest?.count == 4)
    }

    @MainActor @Test func test_trace_clamps_a_window_exceeding_channel_bounds_and_never_over_reads() throws {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: SampleWindow(start: 8, count: 5))

        // Clamped to the 2 remaining samples, and the request issued across the
        // seam never reaches past the channel's sample count.
        #expect(trace.samples.count == 2)
        let request = try #require(source.lastRequest)
        #expect(request.start == 8)
        #expect(request.count == 2)
        #expect(Int(request.start) + Int(request.count) <= 10)   // never over-reads
    }

    @MainActor @Test func test_trace_with_start_beyond_bounds_is_empty_and_issues_no_read() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: SampleWindow(start: 12, count: 3))

        #expect(trace.samples.isEmpty)
        #expect(source.lastRequest == nil)   // a zero-width window never hits the seam
    }

    @MainActor @Test func test_trace_for_out_of_range_channel_index_returns_an_empty_named_trace() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 99, window: .all)

        #expect(trace.name.isEmpty)
        #expect(trace.samples.isEmpty)
        #expect(source.lastRequest == nil)
    }

    // MARK: - trace: degenerate channels / windows

    @MainActor @Test func test_trace_over_an_empty_channel_is_empty_and_issues_no_read() {
        let source = FakeSessionDataSource(banks: [[]])
        let sut = AnalysisSession(session: session([channel("Empty", count: 0)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: .all)

        #expect(trace.name == "Empty")
        #expect(trace.samples.isEmpty)
        #expect(source.lastRequest == nil)   // sampleCount 0 → count clamps to 0
    }

    @MainActor @Test func test_trace_with_a_zero_count_window_issues_no_read() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: SampleWindow(start: 0, count: 0))

        #expect(trace.samples.isEmpty)
        #expect(source.lastRequest == nil)
    }

    @MainActor @Test func test_trace_reads_a_single_sample_channel() {
        let source = FakeSessionDataSource(banks: [bank(1)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 1)]), dataSource: source)

        let trace = sut.trace(channelIndex: 0, window: .all)

        #expect(trace.samples == [PlotSample(time: 0, distance: 0, value: 0)])
        #expect(source.lastRequest?.start == 0)
        #expect(source.lastRequest?.count == 1)
    }

    // MARK: - series

    @MainActor @Test func test_series_reads_windowed_xs_and_values() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let series = sut.series(channelIndex: 0, window: SampleWindow(start: 2, count: 3))

        #expect(series.xs == [2, 3, 4])
        #expect(series.values == [4, 6, 8])
    }

    @MainActor @Test func test_series_for_out_of_range_channel_index_is_empty() {
        let source = FakeSessionDataSource(banks: [bank(4)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 4)]), dataSource: source)

        let series = sut.series(channelIndex: 5, window: .all)

        #expect(series.xs.isEmpty)
        #expect(series.values.isEmpty)
        #expect(source.lastRequest == nil)
    }

    // MARK: - stats

    @MainActor @Test func test_stats_returns_channel_statistics_over_a_time_window() throws {
        let stats = ChannelStats(
            count: 100, min: 1, max: 9, mean: 5, stdPop: 2, stdSample: 2.1, rms: 5.5, range: 8)
        let source = FakeSessionDataSource(banks: [bank(10)], stats: ["Speed": stats])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        let got = try sut.stats(channel: "Speed", window: TimeWindow(start: 0, end: 5))

        #expect(got == stats)
        // The exact channel + window bounds are forwarded across the seam (not
        // swapped, not silently widened to `.all`).
        #expect(source.lastStatsRequest == FakeSessionDataSource.StatsRequest(channel: "Speed", start: 0, end: 5))
    }

    @MainActor @Test func test_stats_throws_for_an_unknown_channel() {
        let source = FakeSessionDataSource(banks: [bank(10)])
        let sut = AnalysisSession(session: session([channel("Speed", count: 10)]), dataSource: source)

        #expect(throws: FakeSessionDataSource.UnknownChannel.self) {
            _ = try sut.stats(channel: "Nope", window: .all)
        }
    }

    @MainActor @Test func test_stats_propagates_a_data_source_error() {
        struct Boom: Error {}
        let source = FakeSessionDataSource(banks: [], statsError: Boom())
        let sut = AnalysisSession(session: session([channel("Speed", count: 1)]), dataSource: source)

        #expect(throws: Boom.self) {
            _ = try sut.stats(channel: "Speed", window: .all)
        }
    }

    // MARK: - retention

    @MainActor @Test func test_session_property_exposes_the_retained_session() {
        let loaded = session([channel("Speed", count: 10), channel("RPM", count: 6)])
        let sut = AnalysisSession(session: loaded, dataSource: FakeSessionDataSource(banks: [bank(10), bank(6)]))

        #expect(sut.session == loaded)
    }

    // MARK: - Store wiring (the .loaded state carries a live pump)

    /// A `SessionLoading` that hands back a preset session + data source, so the
    /// store builds a live `AnalysisSession` without any real decode.
    private final class PumpLoader: SessionLoading, @unchecked Sendable {
        let loaded: LoadedSession
        init(_ loaded: LoadedSession) { self.loaded = loaded }
        func load(
            _ url: URL, onProgress: @escaping @MainActor (DecodeProgress) -> Void
        ) async throws -> LoadedSession { loaded }
    }

    @MainActor @Test func test_loaded_state_carries_a_live_analysis_session() async throws {
        let loaded = session([channel("Speed", count: 4)])
        let source = FakeSessionDataSource(banks: [bank(4)])
        let store = SessionStore(loader: PumpLoader(LoadedSession(session: loaded, dataSource: source)))

        await store.load(url: anyURL)

        let analysis = try #require(store.viewModel?.analysis)
        let trace = analysis.trace(channelIndex: 0, window: .all)
        #expect(trace.name == "Speed")
        #expect(trace.samples.count == 4)
    }

    @MainActor @Test func test_loaded_state_has_no_analysis_when_the_loader_omits_a_data_source() async {
        let loaded = session([channel("Speed", count: 4)])
        let store = SessionStore(loader: PumpLoader(LoadedSession(session: loaded)))

        await store.load(url: anyURL)

        #expect(store.viewModel != nil)
        #expect(store.viewModel?.analysis == nil)
    }

    // MARK: - SessionViewModel equality ignores the derived analysis

    @MainActor @Test func test_view_models_are_equal_when_sessions_match_regardless_of_analysis() {
        let loaded = session([channel("Speed", count: 4)])
        let source = FakeSessionDataSource(banks: [bank(4)])
        let withPump = SessionViewModel(
            session: loaded, analysis: AnalysisSession(session: loaded, dataSource: source))
        let withoutPump = SessionViewModel(session: loaded)

        #expect(withPump == withoutPump)
    }

    @Test func test_view_models_differ_when_their_sessions_differ() {
        let a = SessionViewModel(session: session([channel("A", count: 1)]))
        let b = SessionViewModel(session: session([channel("B", count: 1)]))

        #expect(a != b)
    }
}
