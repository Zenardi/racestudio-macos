import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 session side of auto-sync: which channel is the RPM
/// (resolved like the telemetry overlay's `rpm` role), what span of the session
/// it covers, the offsets worth searching for a clip, and whether this build
/// can estimate at all — all through the ``SessionDataSource`` seam, FFI-free.
@MainActor
@Suite struct AnalysisSessionAudioSyncTests {

    private func session(channels: [Channel], banks: [[DataSample]],
                         estimator: (any AudioSyncEstimating)? = nil) -> AnalysisSession {
        let source = FakeSessionDataSource(banks: banks)
        source.audioSyncEstimatorStub = estimator
        let metadata = SessionMetadata(vehicle: "", track: "", driver: "", session: "", series: "",
                                       logDate: "", logTime: "", datetimeUtc: 0)
        return AnalysisSession(session: Session(metadata: metadata, channels: channels, laps: []),
                               dataSource: source)
    }

    private let speed = Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 10, decimals: 1, sampleCount: 2)
    private let rpm = Channel(name: "RPM", unit: "rpm", sampleRateHz: 20, decimals: 0, sampleCount: 3)
    private let rpmSamples = [DataSample(time: 31.4, value: 2_000), DataSample(time: 400, value: 6_000),
                              DataSample(time: 776.9, value: 3_000)]
    private let speedSamples = [DataSample(time: 0, value: 0), DataSample(time: 1, value: 10)]

    /// The RPM channel is found by its role, wherever it sits in the listing,
    /// and its samples bound the session span the search covers.
    @Test func test_the_rpm_channel_and_its_span_are_resolved() {
        let analysis = session(channels: [speed, rpm], banks: [speedSamples, rpmSamples])

        #expect(analysis.rpmChannel?.channelName == "RPM")
        #expect(analysis.rpmChannel?.channelIndex == 1)
        #expect(analysis.sampleSpan(channelIndex: 1) == 31.4...776.9)
        #expect(analysis.audioSyncSearchRange(videoDuration: 600) == -776.9...568.6)
    }

    /// A session without RPM has no channel, no span and nothing to search.
    @Test func test_a_session_without_rpm_has_nothing_to_search() {
        let analysis = session(channels: [speed], banks: [speedSamples], estimator: FakeEstimator(
            result: .success(.weak(offset: 0))))

        #expect(analysis.rpmChannel == nil)
        #expect(analysis.audioSyncSearchRange(videoDuration: 600) == nil)
        #expect(analysis.sampleSpan(channelIndex: 5) == nil)
        #expect(analysis.audioSyncCoordinator(source: FakeSource()) == nil)
    }

    /// With an RPM channel and a linked estimator the session builds a
    /// coordinator that matches against that channel.
    @Test func test_a_session_with_rpm_and_an_estimator_builds_a_coordinator() async throws {
        let estimator = FakeEstimator(result: .success(.confident(offset: -9)))
        let analysis = session(channels: [speed, rpm], banks: [speedSamples, rpmSamples], estimator: estimator)

        let coordinator = try #require(analysis.audioSyncCoordinator(source: FakeSource()))
        let proposal = try await coordinator.run(searchRange: -10...10) { _ in }

        #expect(analysis.canEstimateAudioSync)
        #expect(proposal == .confident(offset: -9, confidence: 0.9))
        #expect(estimator.calls.first?.rpmChannel == "RPM")
    }

    /// The memo resolves a session's RPM channel once, follows a change of
    /// session, and answers `nil` for none.
    @Test func test_the_rpm_memo_follows_the_session_it_is_asked_about() {
        let withRPM = session(channels: [speed, rpm], banks: [speedSamples, rpmSamples])
        let withoutRPM = session(channels: [speed], banks: [speedSamples])
        let memo = RPMChannelMemo()

        #expect(memo.channelName(in: withRPM) == "RPM")
        #expect(memo.channelName(in: withRPM) == "RPM")
        #expect(memo.channelName(in: withoutRPM) == nil)
        #expect(memo.channelName(in: nil) == nil)
        #expect(memo.channelName(in: withRPM) == "RPM")
    }

    /// An RPM channel whose samples cannot be read spans no session time, so
    /// the memo reports none and the button is disabled rather than dead.
    @Test func test_the_rpm_memo_skips_a_channel_without_readable_samples() {
        let unreadable = session(channels: [speed, rpm], banks: [speedSamples, []])

        #expect(unreadable.rpmChannel?.channelName == "RPM")
        #expect(RPMChannelMemo().channelName(in: unreadable) == nil)
    }

    /// Without the Rust core there is no estimator, hence no coordinator.
    @Test func test_a_build_without_an_estimator_cannot_auto_sync() {
        let analysis = session(channels: [rpm], banks: [rpmSamples])

        #expect(!analysis.canEstimateAudioSync)
        #expect(analysis.audioSyncCoordinator(source: FakeSource()) == nil)
    }
}
