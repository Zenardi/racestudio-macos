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

    // MARK: - Fixture (no logic — fixed footage and clocks)

    private let footage = OpenedFootage(duration: 300, nominalFrameRate: 30)
    private let sessionStart = 1_700_000_000.0

    /// A session reopened with footage synced by engine sound: the saved sync is
    /// in force, but the footage's length is not loaded yet.
    private func reopened() -> VideoDataViewModel {
        let review = VideoReviewModel()
        review.restore(VideoAttachment(bookmark: Data(), displayName: "onboard.mp4", offset: 12.5, rate: 1.0001,
                                       status: .autoAudio(confidence: 0.87)))
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

    /// The panel asked to follow the cursor before the footage had loaded, which
    /// can't seek; once it has, the player is put on the cursor's frame under
    /// the saved sync.
    @Test func test_reopened_footage_shows_the_cursors_frame_under_the_saved_sync() {
        let model = reopened()
        #expect(model.follow(cursorTime: 30, isPlaying: false) == nil)

        let opening = model.footageOpened(footage, cursorTime: 30, isPlaying: false)

        #expect(opening.playhead == 30 * 1.0001 + 12.5)
        #expect(model.displayedTime == 30)
    }

    /// Reopening keeps the saved offset, rate and status, and seeds the
    /// footage's length and frame grid.
    @Test func test_reopening_keeps_the_saved_sync() {
        let model = reopened()

        let opening = model.footageOpened(footage, cursorTime: 30, isPlaying: false)

        #expect(model.review.sync == VideoSyncModel(videoDuration: 300, offset: 12.5, rate: 1.0001))
        #expect(model.review.status == .autoAudio(confidence: 0.87))
        #expect(model.review.frameGrid == FrameGrid(nominalFrameRate: 30))
        #expect(opening.autoOffset == nil)
    }

    // MARK: - New footage

    /// A file date that fits the session aligns new footage, and the player
    /// follows that estimate.
    @Test func test_a_file_date_aligns_new_footage_and_the_player_follows_it() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        let opening = model.footageOpened(dated(lead: 7), cursorTime: 30, isPlaying: false)

        #expect(opening.autoOffset == .applied)
        #expect(model.review.status == .estimated)
        #expect(opening.playhead == 37)
    }

    /// A file date that can't be right is reported and not applied; the player
    /// still shows the cursor's frame.
    @Test func test_an_implausible_file_date_is_reported_and_the_player_still_follows() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        let opening = model.footageOpened(dated(lead: -100_000), cursorTime: 30, isPlaying: false)

        #expect(opening.autoOffset == .implausible)
        #expect(model.review.status == .notSynced)
        #expect(opening.playhead == 30)
    }

    /// A file date never overrides a saved sync.
    @Test func test_a_file_date_never_overrides_a_saved_sync() {
        let model = reopened()

        let opening = model.footageOpened(dated(lead: 7), cursorTime: 30, isPlaying: false)

        #expect(opening.autoOffset == .unavailable)
        #expect(model.review.sync.offset == 12.5)
        #expect(opening.playhead == 30 * 1.0001 + 12.5)
    }

    // MARK: - No seek

    /// A playing player, or one with no cursor to follow yet, is not moved.
    @Test(arguments: zip([30, nil] as [Double?], [true, false]))
    func test_opening_does_not_seek_while_playing_or_without_a_cursor(cursorTime: Double?, isPlaying: Bool) {
        let model = reopened()

        let opening = model.footageOpened(footage, cursorTime: cursorTime, isPlaying: isPlaying)

        #expect(opening.playhead == nil)
    }

    /// Footage whose length can't be read stays unplayable, and the player is
    /// not moved.
    @Test func test_footage_without_a_readable_length_is_not_sought() {
        let model = reopened()

        let opening = model.footageOpened(OpenedFootage(duration: nil, nominalFrameRate: 30), cursorTime: 30,
                                          isPlaying: false)

        #expect(opening.playhead == nil)
        #expect(!model.review.hasVideo)
    }
}
