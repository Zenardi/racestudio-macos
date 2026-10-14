import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for what happens once footage has opened (issue 229): its length and
/// frame grid are seeded, a file date may give new footage a first alignment,
/// and a paused player is put on the cursor's frame under the sync in force —
/// so a reopened session never shows the footage's first frame against data
/// left somewhere else, which reads as a lost sync.
@MainActor
@Suite struct VideoFootageOpeningTests {

    // MARK: - Fixture (no logic — fixed footage and clocks, exact in binary)

    private let footage = OpenedFootage(duration: 300, nominalFrameRate: 30)
    private let sessionStart = 1_700_000_000.0
    /// A sync made by hand, keeping a two-point clock rate: session time `t`
    /// is playhead `t × 1.0625 + 12.5`, so the cursor at 32 s is 46.5 s.
    private let saved = VideoAttachment(bookmark: Data(), displayName: "onboard.mp4", offset: 12.5, rate: 1.0625,
                                        status: .anchored(lap: nil))

    /// A session reopened with synced footage: the saved sync is in force, but
    /// the footage's length is not loaded yet.
    private func reopened() -> VideoDataViewModel {
        let review = VideoReviewModel()
        review.restore(saved)
        return VideoDataViewModel(review: review)
    }

    /// New footage whose file date says the camera started `lead` seconds before
    /// the logger.
    private func dated(lead: Double) -> OpenedFootage {
        OpenedFootage(duration: 300, nominalFrameRate: 30,
                      fileDate: .init(sessionStartEpoch: sessionStart, videoStartEpoch: sessionStart - lead,
                                      sessionDuration: 62))
    }

    // MARK: - A reopened session

    /// Before the footage has loaded, the panel's request to follow the cursor
    /// can't move the player — why it stood on its first frame.
    @Test func test_before_the_footage_has_loaded_the_cursor_cant_move_the_player() {
        #expect(reopened().follow(cursorTime: 32, isPlaying: false) == nil)
    }

    /// Once it has, the player is put on the cursor's frame under the saved
    /// sync.
    @Test func test_once_opened_the_player_stands_on_the_cursors_frame() {
        let opening = reopened().footageOpened(footage, cursorTime: 32, isPlaying: false)

        #expect(opening.playhead == 46.5)
    }

    /// The cursor's session time is put on show, so the HUD matches the frame.
    @Test func test_once_opened_the_cursors_time_is_on_show() {
        let model = reopened()

        _ = model.footageOpened(footage, cursorTime: 32, isPlaying: false)

        #expect(model.displayedTime == 32)
    }

    /// Reopening keeps the saved offset, rate and status.
    @Test func test_reopening_keeps_the_saved_sync() {
        let model = reopened()

        _ = model.footageOpened(footage, cursorTime: 32, isPlaying: false)

        #expect(model.review.stamped(saved) == saved)
    }

    /// The footage's length is seeded.
    @Test func test_opening_seeds_the_footages_length() {
        let model = reopened()

        _ = model.footageOpened(footage, cursorTime: 32, isPlaying: false)

        #expect(model.review.sync.videoDuration == 300)
    }

    /// The footage's frame grid is seeded.
    @Test func test_opening_seeds_the_frame_grid() {
        let model = reopened()

        _ = model.footageOpened(footage, cursorTime: 32, isPlaying: false)

        #expect(model.review.frameGrid == FrameGrid(nominalFrameRate: 30))
    }

    /// Without a file date no guess is made, and none is reported.
    @Test func test_without_a_file_date_no_guess_is_made() {
        #expect(reopened().footageOpened(footage, cursorTime: 32, isPlaying: false).autoOffset == nil)
    }

    // MARK: - New footage

    /// A file date that fits the session aligns new footage.
    @Test func test_a_file_date_that_fits_aligns_new_footage() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.footageOpened(dated(lead: 7), cursorTime: 32, isPlaying: false).autoOffset == .applied)
    }

    /// The player follows the file date's estimate.
    @Test func test_the_player_follows_the_file_dates_estimate() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.footageOpened(dated(lead: 7), cursorTime: 32, isPlaying: false).playhead == 39)
    }

    /// A file date that can't be right is reported, not applied.
    @Test func test_an_implausible_file_date_is_reported() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.footageOpened(dated(lead: -100_000), cursorTime: 32, isPlaying: false).autoOffset
                    == .implausible)
    }

    /// After an implausible file date the player still shows the cursor's frame.
    @Test func test_after_an_implausible_file_date_the_player_still_follows_the_cursor() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.footageOpened(dated(lead: -100_000), cursorTime: 32, isPlaying: false).playhead == 32)
    }

    /// A file date never overrides a saved sync — re-linking a moved file
    /// keeps the alignment it was saved with.
    @Test func test_a_file_date_never_overrides_a_saved_sync() {
        let model = reopened()

        _ = model.footageOpened(dated(lead: 7), cursorTime: 32, isPlaying: false)

        #expect(model.review.stamped(saved) == saved)
    }

    // MARK: - No seek

    /// A playing player, or one with no cursor to follow yet, is not moved.
    @Test(arguments: zip([32, nil] as [Double?], [true, false]))
    func test_opening_does_not_seek_while_playing_or_without_a_cursor(cursorTime: Double?, isPlaying: Bool) {
        let opening = reopened().footageOpened(footage, cursorTime: cursorTime, isPlaying: isPlaying)

        #expect(opening.playhead == nil)
    }

    /// Footage whose length can't be read, or reads as no number, is not
    /// sought.
    @Test(arguments: [nil, .nan] as [Double?])
    func test_footage_without_a_readable_length_is_not_sought(duration: Double?) {
        let unreadable = OpenedFootage(duration: duration, nominalFrameRate: 30)

        #expect(reopened().footageOpened(unreadable, cursorTime: 32, isPlaying: false).playhead == nil)
    }

    /// Such footage stays unplayable.
    @Test(arguments: [nil, .nan] as [Double?])
    func test_footage_without_a_readable_length_stays_unplayable(duration: Double?) {
        let model = reopened()

        _ = model.footageOpened(OpenedFootage(duration: duration, nominalFrameRate: 30), cursorTime: 32,
                                isPlaying: false)

        #expect(!model.review.hasVideo)
    }
}
