import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 two-point sync on `VideoReviewModel`: setting anchors
/// A and B on two lap starts, solving offset + rate from them, the coverage
/// summary and status line that follow every sync action, and carrying the sync
/// through a saved attachment.
///
/// Stepping, status transitions and the file-date guess are covered in
/// `VideoReviewSyncTests`.
@MainActor
@Suite struct VideoReviewTwoPointTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    /// The playhead lap `lap` starts at on footage running 100 ppm fast and
    /// leading the session by 30 s.
    private func frame(ofLap lap: Int) -> Double { Double(lap) * 60 * 1.0001 + 30 }

    /// A stint with anchor A on lap 3 (index 2) and anchor B on lap 14 (index 13),
    /// each on the frame its line crossing shows.
    private func anchored() -> VideoReviewModel {
        let review = VideoReviewFixture.stint()
        review.select(lap: LapID(2))
        review.setAnchor(.a, playhead: frame(ofLap: 2))
        review.select(lap: LapID(13))
        review.setAnchor(.b, playhead: frame(ofLap: 13))
        return review
    }

    // MARK: - Anchors

    /// An anchor needs a section under review to take its session time from.
    @Test func test_an_anchor_needs_a_selection() {
        let review = VideoReviewFixture.stint()

        #expect(!review.setAnchor(.a, playhead: 100))
        #expect(review.anchors.isEmpty)
    }

    /// An anchor pairs the reviewed section's start with the frame on screen,
    /// and remembers the lap it was set on.
    @Test func test_an_anchor_records_the_section_start_and_lap() {
        let review = VideoReviewFixture.stint()
        review.select(lap: LapID(2))

        #expect(review.setAnchor(.a, playhead: 150))
        #expect(review.anchors[.a] == LapAnchor(lap: LapID(2),
                                                anchor: SyncAnchor(sessionTime: 120, videoTime: 150)))
    }

    /// A set anchor names its lap, 1-based — the anchor button's spoken value.
    @Test func test_an_anchor_names_its_lap() {
        let anchor = LapAnchor(lap: LapID(2), anchor: SyncAnchor(sessionTime: 120, videoTime: 150))

        #expect(anchor.label(locale: en) == "set on lap 3")
        #expect(anchor.label(locale: ptBR) == "definida na volta 3")
    }

    /// A non-finite playhead sets no anchor.
    @Test func test_a_non_finite_playhead_sets_no_anchor() {
        let review = VideoReviewFixture.stint()
        review.select(lap: LapID(2))

        #expect(!review.setAnchor(.b, playhead: .nan))
        #expect(review.anchors[.b] == nil)
    }

    // MARK: - Two-point sync

    /// Applying the two anchors solves offset and rate so both line crossings
    /// land exactly on their frames, and says so in the status.
    @Test func test_two_point_sync_lands_both_anchors_on_their_frames() throws {
        let review = anchored()

        let solution = try review.applyTwoPointSync().get()

        #expect(abs(solution.rate - 1.0001) < 1e-12)
        #expect(abs(review.sync.rate - 1.0001) < 1e-12)
        #expect(review.status == .twoPoint(lapA: LapID(2), lapB: LapID(13)))
        review.select(lap: LapID(2))
        #expect(abs((review.seekTarget ?? 0) - frame(ofLap: 2)) < 1e-9)
        review.select(lap: LapID(13))
        #expect(abs((review.seekTarget ?? 0) - frame(ofLap: 13)) < 1e-9)
    }

    /// A third lap between the anchors lands on its frame too — the drift the
    /// rate cancels.
    @Test func test_two_point_sync_corrects_the_laps_in_between() throws {
        let review = anchored()
        _ = try review.applyTwoPointSync().get()

        review.select(lap: LapID(8))

        #expect(abs((review.seekTarget ?? 0) - frame(ofLap: 8)) < 1e-9)
    }

    /// Without both anchors there is nothing to solve: the sync is unchanged.
    @Test func test_two_point_sync_needs_both_anchors() {
        let review = VideoReviewFixture.stint()
        review.select(lap: LapID(2))
        review.setAnchor(.a, playhead: 150)

        #expect(review.applyTwoPointSync() == .failure(.missingAnchor))
        #expect(review.sync == VideoSyncModel(videoDuration: 1_000))
        #expect(review.status == .notSynced)
    }

    /// An absurd anchor pair is rejected and the previous sync is kept intact.
    @Test func test_an_absurd_anchor_pair_keeps_the_previous_sync() {
        let review = VideoReviewFixture.stint()
        review.select(lap: LapID(0))
        review.anchorSelection(toPlayhead: 30) // a good single-point sync
        let previous = review.sync
        review.select(lap: LapID(2))
        review.setAnchor(.a, playhead: 150)
        review.select(lap: LapID(13))
        review.setAnchor(.b, playhead: 900) // the wrong lap's crossing

        guard case .failure(.rateOutOfBounds) = review.applyTwoPointSync() else {
            Issue.record("an implied rate of 750/660 must be rejected")
            return
        }
        #expect(review.sync == previous)
        #expect(review.status == .anchored(lap: LapID(0)))
    }

    /// Every rejection reads as a sentence the operator can act on.
    @Test func test_two_point_errors_read_clearly() {
        #expect(TwoPointSyncError.missingAnchor.message(locale: en)
                == "Set anchor A and anchor B on two lap starts first.")
        #expect(TwoPointSyncError.anchorsTooClose.message(locale: en)
                == "Anchors A and B must be at least 10 s apart — set them on laps further apart.")
        #expect(TwoPointSyncError.rateOutOfBounds(1.01).message(locale: en)
                == "These anchors imply a +1.00% clock difference — more than any camera drifts, "
                + "so one is on the wrong frame or lap. The previous sync is kept.")
        #expect(TwoPointSyncError.rateOutOfBounds(0.98).message(locale: ptBR).contains("-2,00%"))
        #expect(TwoPointSyncError.nonFinite.message(locale: en)
                == "Those anchors are not valid times — set them again.")
    }

    // MARK: - Coverage and status line

    /// The coverage summary and status line follow every sync action at once.
    @Test func test_status_line_follows_every_sync_action() {
        let review = VideoReviewFixture.stint(videoDuration: 860)
        #expect(review.statusLine(locale: en) == "Not synced · footage covers laps 1–14 (14 of 16)")

        review.setOffset(-50)

        #expect(review.coverageSummary == CoverageSummary(firstLap: LapID(1), lastLap: LapID(14),
                                                          coveredLaps: 14, totalLaps: 16))
        #expect(review.statusLine(locale: en) == "Synced by hand · footage covers laps 2–15 (14 of 16)")
    }

    // MARK: - Persistence and reset

    /// Restoring a saved attachment brings back its offset, rate and status.
    @Test func test_restoring_an_attachment_brings_back_the_sync() {
        let review = VideoReviewFixture.stint()
        let saved = VideoAttachment(bookmark: Data("bm".utf8), displayName: "onboard.mp4", offset: 30,
                                    rate: 1.0001, status: .twoPoint(lapA: LapID(2), lapB: LapID(13)))

        review.restore(saved)

        #expect(review.sync == VideoSyncModel(videoDuration: 1_000, offset: 30, rate: 1.0001))
        #expect(review.status == .twoPoint(lapA: LapID(2), lapB: LapID(13)))
    }

    /// The attachment a save writes carries the sync in force.
    @Test func test_stamping_an_attachment_captures_the_sync() throws {
        let review = anchored()
        _ = try review.applyTwoPointSync().get()

        let stamped = review.stamped(VideoAttachment(bookmark: Data("bm".utf8), displayName: "onboard.mp4"))

        #expect(stamped.offset == review.sync.offset)
        #expect(stamped.rate == review.sync.rate)
        #expect(stamped.status == .twoPoint(lapA: LapID(2), lapB: LapID(13)))
    }

    /// Loading the asset's duration keeps the solved rate.
    @Test func test_setting_the_duration_keeps_the_rate() throws {
        let review = anchored()
        _ = try review.applyTwoPointSync().get()

        review.setVideoDuration(500)

        #expect(abs(review.sync.rate - 1.0001) < 1e-12)
    }

    /// Detaching the footage forgets its alignment entirely, so the next video
    /// starts unsynced.
    @Test func test_detaching_forgets_the_sync() throws {
        let review = anchored()
        _ = try review.applyTwoPointSync().get()

        review.setFrameRate(25)

        review.detachVideo()

        #expect(review.sync == VideoSyncModel(videoDuration: 0))
        #expect(review.frameGrid == .fallback)
        #expect(review.status == .notSynced)
        #expect(review.anchors.isEmpty)
    }
}
