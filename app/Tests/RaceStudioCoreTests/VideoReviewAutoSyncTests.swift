import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 auto-sync on `VideoReviewModel`: a run reports its
/// progress and ends in a proposal without touching the sync; only a confident
/// proposal the operator applies changes it (to ``SyncStatus/autoAudio(confidence:)``);
/// cancelling at any point leaves the existing sync exactly as it was; and an
/// applied sync can still be refined by frame steps or replaced by two-point.
@MainActor
@Suite struct VideoReviewAutoSyncTests {

    private func stint() -> VideoReviewModel { VideoReviewFixture.stint(videoDuration: 1_000) }

    /// Yield until `condition` holds (bounded), for state hopping off the main actor.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Running

    /// A run ends in its proposal; the alignment in force is untouched until the
    /// operator applies it.
    @Test func test_a_run_finishes_with_a_proposal_and_leaves_the_sync_alone() async {
        let review = stint()
        review.setOffset(4)

        await review.runAutoSync(fakeCoordinator(FakeSource(startTime: 0.5)), searchRange: -400...200)

        #expect(review.autoSyncState == .finished(.confident(offset: -9.5, confidence: 0.9)))
        #expect(review.sync.offset == 4)
        #expect(review.status == .anchored(lap: nil))
    }

    /// While the audio is read the state carries the progress.
    @Test func test_a_running_sync_reports_its_progress() async {
        let review = stint()
        let run = Task { await review.runAutoSync(fakeCoordinator(FakeSource(hangs: true)), searchRange: -9...9) }

        await eventually { review.autoSyncState == .running(.reading(0.5)) }

        #expect(review.autoSyncState == .running(.reading(0.5)))
        #expect(review.autoSyncState.isRunning)
        run.cancel()
        await run.value
    }

    /// Only a finished run carries a proposal.
    @Test func test_only_a_finished_state_carries_a_proposal() {
        let proposal = AudioSyncProposal.weak(offset: 2, confidence: 0.1)

        #expect(AutoSyncState.finished(proposal).proposal == proposal)
        #expect(AutoSyncState.idle.proposal == nil)
        #expect(AutoSyncState.running(.matching).proposal == nil)
        #expect(!AutoSyncState.finished(proposal).isRunning)
    }

    // MARK: - Applying

    /// Applying a confident proposal syncs the footage at unit rate and marks it
    /// synced from engine sound.
    @Test func test_applying_a_confident_proposal_syncs_and_marks_auto_audio() async {
        let review = stint()
        await review.runAutoSync(fakeCoordinator(), searchRange: -400...200)

        let applied = review.applyAudioSync(.confident(offset: -113.632, confidence: 0.96))

        #expect(applied)
        #expect(review.sync.offset == -113.632)
        #expect(review.sync.rate == 1)
        #expect(review.status == .autoAudio(confidence: 0.96))
        #expect(review.autoSyncState == .idle)
    }

    /// A weak or unavailable proposal is never applied, and footage that is not
    /// there cannot be synced.
    @Test func test_only_a_confident_proposal_on_real_footage_applies() {
        let review = stint()
        review.setOffset(4)
        let empty = VideoReviewModel(timeline: VideoReviewFixture.timeline())

        #expect(!review.applyAudioSync(.weak(offset: -9, confidence: 0.3)))
        #expect(!review.applyAudioSync(.unavailable(.flatRPM)))
        #expect(!empty.applyAudioSync(.confident(offset: -9, confidence: 0.9)))
        #expect(review.sync.offset == 4)
        #expect(review.status == .anchored(lap: nil))
        #expect(empty.status == .notSynced)
    }

    /// An audio sync is an offset at equal clocks: it replaces a two-point rate.
    @Test func test_applying_resets_a_two_point_rate() {
        let review = stint()
        review.restore(VideoAttachment(bookmark: Data(), displayName: "a.mp4", offset: 3, rate: 1.0002,
                                       status: .twoPoint(lapA: LapID(1), lapB: LapID(8))))

        review.applyAudioSync(.confident(offset: -2, confidence: 0.8))

        #expect(review.sync.rate == 1)
        #expect(review.status == .autoAudio(confidence: 0.8))
    }

    // MARK: - Cancelling

    /// Cancelling mid-read stops the run and leaves the existing sync untouched.
    @Test func test_cancelling_mid_read_leaves_the_sync_unchanged() async {
        let review = stint()
        review.setOffset(12)
        let run = Task { await review.runAutoSync(fakeCoordinator(FakeSource(hangs: true)), searchRange: -9...9) }
        await eventually { review.autoSyncState.isRunning }

        run.cancel()
        await run.value

        #expect(review.autoSyncState == .idle)
        #expect(review.sync.offset == 12)
        #expect(review.status == .anchored(lap: nil))
    }

    /// The Cancel button returns the panel to idle at once; a result arriving
    /// afterwards is dropped.
    @Test func test_cancel_is_immediate_and_drops_a_late_result() async {
        let review = stint()
        let run = Task { await review.runAutoSync(fakeCoordinator(FakeSource(delay: 50_000_000)), searchRange: -9...9) }
        await eventually { review.autoSyncState.isRunning }

        review.cancelAutoSync()

        #expect(review.autoSyncState == .idle)
        await run.value
        #expect(review.autoSyncState == .idle)
        #expect(review.sync.offset == 0)
    }

    /// Dismissing a result, or detaching the footage, returns to idle.
    @Test func test_dismissing_or_detaching_returns_to_idle() async {
        let review = stint()
        await review.runAutoSync(fakeCoordinator(), searchRange: -400...200)

        review.dismissAutoSync()
        #expect(review.autoSyncState == .idle)

        await review.runAutoSync(fakeCoordinator(), searchRange: -400...200)
        review.detachVideo()
        #expect(review.autoSyncState == .idle)
    }

    // MARK: - Refining

    /// A frame step refines an audio sync and keeps its status; a two-point
    /// sync on top replaces it.
    @Test func test_an_audio_sync_can_be_refined() {
        let review = stint()
        review.setFrameRate(Double(Float(29.97003)))
        review.applyAudioSync(.confident(offset: -5, confidence: 0.9))

        review.stepOffset(frames: 1)

        #expect(abs(review.sync.offset - (-5 + 1_001.0 / 30_000.0)) < 1e-12)
        #expect(review.status == .autoAudio(confidence: 0.9))

        review.select(lap: LapID(1))
        review.setAnchor(.a, playhead: 55)
        review.select(lap: LapID(8))
        review.setAnchor(.b, playhead: 476)
        _ = review.applyTwoPointSync()

        #expect(review.status == .twoPoint(lapA: LapID(1), lapB: LapID(8)))
    }
}
