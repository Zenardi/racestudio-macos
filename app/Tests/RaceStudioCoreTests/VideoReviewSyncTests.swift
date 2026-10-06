import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 sync controls on `VideoReviewModel`: frame-accurate
/// trimming (`,` / `.` one frame, `⇧` 0.1 s, `⌥` 1 s), the sync **status** each
/// action leaves behind, and the typed outcome of the file-date guess.
///
/// Two-point sync, anchors, coverage and persistence are covered in
/// `VideoReviewTwoPointTests`; both suites share ``VideoReviewFixture/stint(videoDuration:)``.
@MainActor
@Suite struct VideoReviewSyncTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private func stint(videoDuration: Double = 1_000) -> VideoReviewModel {
        VideoReviewFixture.stint(videoDuration: videoDuration)
    }

    // MARK: - Frame stepping

    /// At 29.97 fps one frame step moves the offset by exactly 1001/30000 s, and a
    /// step back returns it.
    @Test func test_frame_step_moves_one_ntsc_frame() {
        let review = stint()
        review.setFrameRate(Double(Float(29.97003)))

        review.stepOffset(frames: 1)
        #expect(abs(review.sync.offset - 1_001.0 / 30_000.0) < 1e-12)

        review.stepOffset(frames: -1)
        #expect(review.sync.offset == 0)
    }

    /// Frame steps keep the offset on the footage's frame grid, even from a trim
    /// that left it between two frames.
    @Test func test_frame_steps_keep_the_offset_on_the_grid() {
        let review = stint()
        review.setFrameRate(25)
        review.setOffset(0.05)

        review.stepOffset(frames: 1)

        #expect(review.sync.offset == 0.08)
    }

    /// Until the asset's rate is known, a frame is a 30 fps frame.
    @Test func test_frames_default_to_30_fps() {
        let review = stint()

        review.stepOffset(frames: 1)

        #expect(review.frameGrid == .fallback)
        #expect(review.sync.offset == 1.0 / 30.0)
    }

    /// An unknown nominal rate falls back to 30 fps rather than a zero frame.
    @Test func test_unknown_frame_rate_falls_back_to_30_fps() {
        let review = stint()
        review.setFrameRate(0)

        #expect(review.frameGrid == .fallback)
    }

    /// Second steps move the offset by exactly that many seconds, unsnapped.
    @Test func test_second_steps_move_exactly() {
        let review = stint()
        review.setOffset(2)

        review.stepOffset(seconds: 0.1)
        #expect(abs(review.sync.offset - 2.1) < 1e-12)

        review.stepOffset(seconds: -1)
        #expect(abs(review.sync.offset - 1.1) < 1e-12)
    }

    /// A non-finite step is ignored rather than poisoning the offset.
    @Test func test_non_finite_second_step_is_ignored() {
        let review = stint()
        review.setOffset(2)

        review.stepOffset(seconds: .nan)

        #expect(review.sync.offset == 2)
    }

    /// Each keyboard nudge moves the offset by its amount: a frame (`,` / `.`),
    /// 0.1 s (`⇧`) or 1 s (`⌥`), backward or forward.
    @Test(arguments: [(OffsetNudge.frameBackward, -0.04), (.frameForward, 0.04),
                      (.tenthBackward, -0.1), (.tenthForward, 0.1),
                      (.secondBackward, -1), (.secondForward, 1)])
    func test_each_nudge_moves_by_its_amount(nudge: OffsetNudge, expected: Double) {
        let review = stint()
        review.setFrameRate(25)

        review.nudge(nudge)

        #expect(review.sync.offset == expected)
    }

    /// The keys follow the spec: `,` back and `.` forward, a frame bare, 0.1 s with
    /// `⇧`, 1 s with `⌥`.
    @Test func test_nudge_keys_follow_the_spec() {
        #expect(OffsetNudge.allCases.map(\.key) == [",", ".", ",", ".", ",", "."])
        #expect(OffsetNudge.allCases.map(\.modifier) == [.none, .none, .shift, .shift, .option, .option])
    }

    /// Every nudge has a spoken label for VoiceOver in both languages.
    @Test func test_every_nudge_has_a_label() {
        for nudge in OffsetNudge.allCases {
            #expect(!L10n.isFlagged(nudge.label(locale: en)))
            #expect(nudge.label(locale: en) != nudge.label(locale: ptBR))
        }
    }

    // MARK: - Status

    /// Nothing is synced until the operator (or the file date) aligns it.
    @Test func test_starts_not_synced() {
        #expect(stint().status == .notSynced)
    }

    /// Anchoring the selected lap's start marks the sync as anchored on that lap.
    @Test func test_anchoring_a_lap_marks_it_anchored_there() {
        let review = stint()
        review.select(lap: LapID(2))

        review.anchorSelection(toPlayhead: 200)

        #expect(review.status == .anchored(lap: LapID(2)))
    }

    /// Anchoring to a non-finite playhead changes nothing — not even the status.
    @Test func test_anchoring_to_a_non_finite_playhead_changes_nothing() {
        let review = stint()
        review.select(lap: LapID(2))

        #expect(!review.anchorSelection(toPlayhead: .nan))
        #expect(review.status == .notSynced)
        #expect(review.sync.offset == 0)
    }

    /// Trimming footage nobody aligned yet is a sync by hand.
    @Test func test_trimming_an_unsynced_video_is_a_sync_by_hand() {
        let review = stint()

        review.stepOffset(frames: 1)

        #expect(review.status == .anchored(lap: nil))
    }

    /// Trimming a file-date estimate takes it over by hand, too.
    @Test func test_trimming_an_estimate_is_a_sync_by_hand() {
        let review = stint()
        review.applyAutoOffset(sessionStartEpoch: 1_000_030, videoStartEpoch: 1_000_000, sessionDuration: 960)

        review.setOffset(31)

        #expect(review.status == .anchored(lap: nil))
    }

    /// Trimming an anchored sync refines it — the anchor lap is kept.
    @Test func test_trimming_keeps_the_anchor_lap() {
        let review = stint()
        review.select(lap: LapID(2))
        review.anchorSelection(toPlayhead: 200)

        review.stepOffset(frames: 1)
        review.stepOffset(seconds: 1)

        #expect(review.status == .anchored(lap: LapID(2)))
    }

    // MARK: - The file-date guess

    /// A file date that overlaps the session is applied, and labelled estimated.
    @Test func test_a_plausible_file_date_is_applied_as_an_estimate() {
        let review = stint()

        let outcome = review.applyAutoOffset(sessionStartEpoch: 1_000_030, videoStartEpoch: 1_000_000,
                                             sessionDuration: 960)

        #expect(outcome == .applied)
        #expect(review.sync.offset == 30)
        #expect(review.status == .estimated)
    }

    /// A file re-exported two days after the session proposes nothing: the
    /// alignment and the status are left alone.
    @Test func test_an_implausible_file_date_is_refused() {
        let review = stint()

        let outcome = review.applyAutoOffset(sessionStartEpoch: 1_000_000, videoStartEpoch: 1_172_800,
                                             sessionDuration: 960)

        #expect(outcome == .implausible)
        #expect(review.sync.offset == 0)
        #expect(review.status == .notSynced)
    }

    /// Without both clocks there is no guess to make.
    @Test func test_a_missing_clock_is_unavailable() {
        #expect(stint().applyAutoOffset(sessionStartEpoch: 0, videoStartEpoch: 1_000_000,
                                        sessionDuration: 960) == .unavailable)
    }

    /// Without footage (or a session length) the guess cannot be tested — it is
    /// unavailable, not "implausible".
    @Test func test_no_footage_or_session_length_is_unavailable() {
        #expect(stint(videoDuration: 0).applyAutoOffset(sessionStartEpoch: 1_000_030, videoStartEpoch: 1_000_000,
                                                        sessionDuration: 960) == .unavailable)
        #expect(stint().applyAutoOffset(sessionStartEpoch: 1_000_030, videoStartEpoch: 1_000_000,
                                        sessionDuration: 0) == .unavailable)
    }

    /// A file date never overrides the operator's own sync — re-linking a moved
    /// file keeps the alignment it was saved with.
    @Test func test_a_file_date_never_overrides_an_operator_sync() {
        let review = stint()
        review.select(lap: LapID(2))
        review.anchorSelection(toPlayhead: 200)

        let outcome = review.applyAutoOffset(sessionStartEpoch: 1_000_030, videoStartEpoch: 1_000_000,
                                             sessionDuration: 960)

        #expect(outcome == .unavailable)
        #expect(review.sync.offset == 80)
        #expect(review.status == .anchored(lap: LapID(2)))
    }

    /// Only a refused date has something to tell the operator.
    @Test func test_only_an_implausible_date_has_a_message() {
        #expect(AutoOffsetOutcome.implausible.message(locale: en)
                == "The video’s date doesn’t match this session — align it on a lap start")
        #expect(AutoOffsetOutcome.implausible.message(locale: ptBR)
                == "A data do vídeo não corresponde a esta sessão — alinhe-o no início de uma volta")
        #expect(AutoOffsetOutcome.applied.message(locale: en) == nil)
        #expect(AutoOffsetOutcome.unavailable.message(locale: en) == nil)
    }
}
