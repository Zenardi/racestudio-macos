import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `VideoReviewModel` (issue 9.6): which lap or sector is under
/// review, where that puts the shared cursor and the playhead, and whether the
/// attached footage actually covers the section.
///
/// It owns no AVKit — the shell's `AVPlayer` asks it where to seek — so every
/// rule is demonstrable here. Navigating the grid, anchoring the alignment, and
/// re-cutting the timeline are covered in `VideoReviewNavigationTests`; both
/// suites read one shared fixture (``VideoReviewFixture``).
@MainActor
@Suite struct VideoReviewModelTests {

    private func timeline() -> LapSectorTimeline { VideoReviewFixture.timeline() }
    private func model() -> VideoReviewModel { VideoReviewFixture.model() }
    private func splitID(_ index: Int) -> Int { VideoReviewFixture.splitID(index) }

    // MARK: - Selection

    /// Nothing is under review until the operator picks something.
    @Test func test_starts_with_no_selection() {
        let review = model()

        #expect(review.selectedLap == nil)
        #expect(review.selectedSpan == nil)
        #expect(review.selectedLabel == nil)
        #expect(!review.canPlaySelection)
        #expect(review.seekTarget == nil)
    }

    /// Selecting a lap puts the whole lap under review.
    @Test func test_selecting_a_lap_reviews_the_whole_lap() {
        let review = model()
        review.select(lap: LapID(1))

        #expect(review.scope == .lap)
        #expect(review.selectedSpan == SessionTimeSpan(start: 18, end: 24))
        #expect(review.selectedLabel == "Lap 2", "laps are labelled 1-based, as everywhere else")
    }

    /// Selecting a sector narrows the review to that split of that lap.
    @Test func test_selecting_a_sector_reviews_one_split_of_one_lap() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(1))

        #expect(review.scope == .sector)
        #expect(review.selectedSpan == SessionTimeSpan(start: 13, end: 18))
        #expect(review.selectedLabel == "Lap 1 · S2")
    }

    /// Selecting an unknown lap or split leaves the previous review intact rather
    /// than blanking the panel.
    @Test func test_unknown_selection_is_ignored() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(0))

        review.select(lap: LapID(42))
        review.select(lap: LapID(0), splitID: -7)

        #expect(review.selectedLabel == "Lap 1 · S1", "the valid selection still stands")
    }

    /// Clearing returns the panel to free scrubbing.
    @Test func test_clearing_the_selection_frees_the_player() {
        let review = model()
        review.select(lap: LapID(0))
        review.clearSelection()

        #expect(review.selectedSpan == nil)
        #expect(review.playbackAction(atPlayhead: 100) == .none)
    }

    // MARK: - Seeking

    /// The selection's start is where both the shared cursor and the playhead go.
    @Test func test_selection_gives_a_cursor_and_a_playhead_target() {
        let review = model()
        review.setOffset(10) // the footage leads the session by 10 s
        review.select(lap: LapID(0), splitID: splitID(1)) // session 13…18

        #expect(review.cursorTarget == 13, "the cursor goes to the section's session time")
        #expect(review.seekTarget == 23, "the playhead goes to the mapped video time")
        #expect(review.videoWindow == 23...28)
    }

    /// With no footage there is nothing to seek, even with a section selected.
    @Test func test_without_footage_there_is_no_seek_target() {
        let review = VideoReviewModel(timeline: timeline(), sync: VideoSyncModel(videoDuration: 0))
        review.select(lap: LapID(0))

        #expect(review.cursorTarget == 10, "the cursor can still go there")
        #expect(review.seekTarget == nil, "but there is no footage to seek")
        #expect(!review.canPlaySelection)
    }

    // MARK: - Coverage

    /// A section the footage covers is playable.
    @Test func test_a_covered_section_is_playable() {
        let review = model()
        review.select(lap: LapID(0))

        #expect(review.coverage == .full)
        #expect(review.canPlaySelection)
    }

    /// A section filmed only in part is still playable, and says so.
    @Test func test_a_partly_filmed_section_is_flagged() {
        let review = VideoReviewModel(timeline: timeline(), sync: VideoSyncModel(videoDuration: 15))
        review.select(lap: LapID(0)) // session 10…18 against 15 s of footage

        #expect(review.coverage == .partial)
        #expect(review.canPlaySelection, "what was filmed can still be reviewed")
    }

    /// A section outside the footage cannot be played — the grid greys it instead
    /// of seeking to a clamped, wrong frame.
    @Test func test_an_unfilmed_section_cannot_be_played() {
        let review = model()
        review.setOffset(-500) // the footage ends long before this lap
        review.select(lap: LapID(1))

        #expect(review.coverage == .none)
        #expect(!review.canPlaySelection)
        #expect(review.playbackAction(atPlayhead: 0) == .none, "never loop into a window we don't have")
    }
}
