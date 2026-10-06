import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 auto-sync **coordinator**: decode the footage's
/// audio, match it against the session's RPM, and turn the result into a
/// proposal on the video's clock — honouring cancellation between steps. The
/// audio source and the estimator are fakes, so no media or Rust is involved.
@Suite struct AudioSyncCoordinatorTests {

    // MARK: - Running

    /// The decoded clip goes to the estimator with the search window moved onto
    /// the clip's own clock, and the estimate comes back on the video's.
    @Test func test_a_confident_match_is_proposed_on_the_video_clock() async throws {
        let estimator = FakeEstimator(result: .success(.confident(offset: -10)))
        let coordinator = AudioSyncCoordinator(source: FakeSource(startTime: 0.5), estimator: estimator,
                                               rpmChannel: "RPM")

        let proposal = try await coordinator.run(searchRange: -400...200) { _ in }

        #expect(proposal == .confident(offset: -9.5, confidence: 0.9))
        let call = try #require(estimator.calls.first)
        #expect(call.rpmChannel == "RPM")
        #expect(call.sampleRate == 8_000)
        #expect(call.samples == 3)
        #expect(call.searchRange == -400.5...199.5)
    }

    /// Progress reports decoding, then matching, in order.
    @Test func test_progress_reports_reading_then_matching() async throws {
        let phases = PhaseLog()
        let coordinator = AudioSyncCoordinator(source: FakeSource(startTime: 0),
                                               estimator: FakeEstimator(result: .success(.weak(offset: 1))),
                                               rpmChannel: "RPM")

        _ = try await coordinator.run(searchRange: -10...10) { phases.record($0) }

        #expect(phases.values == [.reading(0.5), .reading(1), .matching])
    }

    /// A weak estimate is proposed as weak.
    @Test func test_a_weak_match_is_proposed_as_weak() async throws {
        let coordinator = AudioSyncCoordinator(source: FakeSource(startTime: 0),
                                               estimator: FakeEstimator(result: .success(.weak(offset: 3))),
                                               rpmChannel: "RPM")

        #expect(try await coordinator.run(searchRange: -10...10) { _ in } == .weak(offset: 3, confidence: 0.2))
    }

    /// The source's and the estimator's typed refusals become unavailable
    /// proposals; anything untyped reads as unreadable audio or a failed match.
    @Test func test_failures_become_unavailable_proposals() async throws {
        let noAudio = AudioSyncCoordinator(source: FakeSource(failure: AudioSyncFailure.noAudioTrack),
                                           estimator: FakeEstimator(result: .success(.weak(offset: 0))),
                                           rpmChannel: "RPM")
        let broken = AudioSyncCoordinator(source: FakeSource(failure: CocoaError(.fileReadCorruptFile)),
                                          estimator: FakeEstimator(result: .success(.weak(offset: 0))),
                                          rpmChannel: "RPM")
        let flat = AudioSyncCoordinator(source: FakeSource(startTime: 0),
                                        estimator: FakeEstimator(result: .failure(AudioSyncFailure.flatRPM)),
                                        rpmChannel: "RPM")
        let odd = AudioSyncCoordinator(source: FakeSource(startTime: 0),
                                       estimator: FakeEstimator(result: .failure(CocoaError(.featureUnsupported))),
                                       rpmChannel: "RPM")

        #expect(try await noAudio.run(searchRange: -1...1) { _ in } == .unavailable(.noAudioTrack))
        #expect(try await broken.run(searchRange: -1...1) { _ in } == .unavailable(.unreadableAudio))
        #expect(try await flat.run(searchRange: -1...1) { _ in } == .unavailable(.flatRPM))
        #expect(try await odd.run(searchRange: -1...1) { _ in } == .unavailable(.estimationFailed))
    }

    // MARK: - Cancellation

    /// Cancelling while the audio is being read throws `CancellationError` and
    /// never reaches the estimator.
    @Test func test_cancelling_mid_read_throws_and_skips_the_estimate() async throws {
        let estimator = FakeEstimator(result: .success(.confident(offset: 0)))
        let coordinator = AudioSyncCoordinator(source: FakeSource(hangs: true), estimator: estimator,
                                               rpmChannel: "RPM")
        let run = Task { try await coordinator.run(searchRange: -1...1) { _ in } }

        run.cancel()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(estimator.calls.isEmpty)
    }

    // MARK: - Search range

    /// Every offset that puts some of the session on the footage is searched:
    /// from the session's end at video time 0 to its start at the clip's end.
    @Test func test_search_range_spans_every_overlapping_offset() {
        let range = AudioSyncCoordinator.searchRange(videoDuration: 600, sessionSpan: 31.4...776.9)

        #expect(range == -776.9...568.6)
    }

    /// A degenerate input still yields a valid range.
    @Test func test_search_range_never_inverts() {
        let range = AudioSyncCoordinator.searchRange(videoDuration: 0, sessionSpan: 0...0)

        #expect(range == 0...0)
    }
}
