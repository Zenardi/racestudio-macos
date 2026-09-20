import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.6 additions to `VideoSyncModel`: mapping a whole
/// **session-time window** (a lap or a sector) onto the footage, reporting how
/// much of that window the footage actually covers, exact track-anchored
/// alignment, and the wall-clock first guess.
///
/// The 9.5 mapping (`videoTime` / `cursorTime` / the ±60 s cursor nudge) is
/// unchanged and covered by `VideoSyncModelTests`; these are strictly additive.
@Suite struct VideoSyncWindowTests {

    /// A 120 s video whose footage leads the session clock by 10 s.
    private func synced() -> VideoSyncModel {
        VideoSyncModel(videoDuration: 120, offset: 10)
    }

    // MARK: - Window mapping

    /// Given a lap or sector window in session time, when it is projected, both
    /// ends carry the offset — so "play this sector" plays exactly that stretch.
    @Test func test_session_window_maps_to_a_video_window() {
        #expect(synced().videoRange(for: SessionTimeSpan(start: 20, end: 35)) == 30...45)
    }

    /// A window running past the footage is clamped to it, so a seek can never
    /// leave the asset's bounds.
    @Test func test_window_is_clamped_to_the_footage() {
        let sync = synced() // duration 120, offset 10

        #expect(sync.videoRange(for: SessionTimeSpan(start: 100, end: 200)) == 110...120,
                "the tail clamps to the end")
        #expect(sync.videoRange(for: SessionTimeSpan(start: -50, end: 5)) == 0...15,
                "the head clamps to zero")
    }

    /// A reversed or non-finite window never produces an invalid range — the
    /// result is always a well-formed (possibly empty) span.
    @Test func test_degenerate_window_stays_well_formed() {
        let sync = synced()

        let reversed = sync.videoRange(for: SessionTimeSpan(start: 35, end: 20))
        #expect(reversed.lowerBound <= reversed.upperBound)
        #expect(sync.videoRange(for: SessionTimeSpan(start: .nan, end: .nan)) == 0...0)
        #expect(VideoSyncModel(videoDuration: 0).videoRange(for: SessionTimeSpan(start: 10, end: 20))
                == 0...0)
    }

    // MARK: - Coverage

    /// A window wholly inside the footage is fully covered — it is playable.
    @Test func test_window_inside_the_footage_is_fully_covered() {
        #expect(synced().coverage(of: SessionTimeSpan(start: 20, end: 35)) == .full)
    }

    /// A window that only overlaps the footage is partial: the panel can play what
    /// exists but must say the section is not fully filmed.
    @Test func test_window_overlapping_an_edge_is_partial() {
        let sync = synced() // footage covers session times -10…110

        #expect(sync.coverage(of: SessionTimeSpan(start: 100, end: 130)) == .partial,
                "runs off the end of the footage")
        #expect(sync.coverage(of: SessionTimeSpan(start: -30, end: 5)) == .partial,
                "starts before the footage")
    }

    /// A window entirely outside the footage is not playable at all — the grid
    /// greys it rather than seeking to a clamped, wrong frame.
    @Test func test_window_outside_the_footage_is_uncovered() {
        let sync = synced()

        #expect(sync.coverage(of: SessionTimeSpan(start: 200, end: 260)) == .none,
                "long after the footage ends")
        #expect(sync.coverage(of: SessionTimeSpan(start: -100, end: -50)) == .none,
                "long before the footage starts")
    }

    /// With no footage loaded nothing is covered, whatever the window.
    @Test func test_empty_video_covers_nothing() {
        #expect(VideoSyncModel(videoDuration: 0, offset: 10)
                    .coverage(of: SessionTimeSpan(start: 0, end: 10)) == .none)
    }

    /// A non-finite window cannot be judged covered — it reports uncovered rather
    /// than guessing.
    @Test func test_nonfinite_window_is_uncovered() {
        #expect(synced().coverage(of: SessionTimeSpan(start: .nan, end: .nan)) == .none)
    }

    // MARK: - Track-anchored alignment

    /// Given the operator scrubs the footage to the frame where a lap begins, when
    /// they anchor it to that lap's session time, the offset lines the two up
    /// exactly.
    @Test func test_alignment_to_a_lap_start_is_exact() {
        let aligned = synced().aligned(sessionTime: 90, toPlayhead: 12)

        #expect(aligned.offset == -78, "offset = playhead − session time")
        #expect(aligned.videoTime(forCursorTime: 90) == 12, "the anchored frame is the one on screen")
        #expect(aligned.videoDuration == 120, "re-aligning keeps the footage")
    }

    /// A camera started minutes before the session needs an offset far outside the
    /// ±60 s nudge range — track-anchored alignment must not clamp it away.
    @Test func test_alignment_is_not_limited_to_the_nudge_range() {
        let aligned = synced().aligned(sessionTime: 600, toPlayhead: 5)

        #expect(aligned.offset == -595)
        #expect(abs(aligned.offset) > VideoSyncModel.offsetRange.upperBound,
                "the coarse anchor is free of the fine-trim bound")
        #expect(aligned.videoTime(forCursorTime: 600) == 5)
    }

    /// Non-finite inputs leave the mapping untouched rather than poisoning it.
    @Test func test_alignment_ignores_nonfinite_input() {
        let sync = synced()

        #expect(sync.aligned(sessionTime: .nan, toPlayhead: 10) == sync)
        #expect(sync.aligned(sessionTime: 10, toPlayhead: .infinity) == sync)
    }

    /// The fine-trim slider spans ±60 s **around the current offset**, so a coarse
    /// anchor can still be nudged frame-accurately afterwards.
    @Test func test_trim_range_brackets_the_current_offset() {
        let sync = VideoSyncModel(videoDuration: 120, offset: -595)
        let trim = sync.trimRange

        #expect(trim.contains(sync.offset), "the current offset sits inside its own trim range")
        #expect(trim.lowerBound == -655)
        #expect(trim.upperBound == -535)
        #expect(trim.upperBound - trim.lowerBound == 120, "±60 s either way")
    }

    // MARK: - Wall-clock first guess

    /// Given both the session and the video know when they started, the initial
    /// offset is the difference between those two wall clocks.
    @Test func test_wall_clock_offset_is_the_start_difference() {
        // The camera rolled 90 s before the logger started.
        let offset = VideoSyncModel.autoOffset(sessionStartEpoch: 1_000_090, videoStartEpoch: 1_000_000)

        #expect(offset == 90)
    }

    /// Applying the wall-clock guess puts the session origin at the right frame.
    @Test func test_wall_clock_guess_places_the_session_origin() throws {
        let offset = try #require(
            VideoSyncModel.autoOffset(sessionStartEpoch: 1_000_090, videoStartEpoch: 1_000_000))
        let sync = VideoSyncModel(videoDuration: 600).withOffset(offset)

        #expect(sync.videoTime(forCursorTime: 0) == 90, "session t=0 is 90 s into the footage")
        #expect(sync.videoTime(forCursorTime: 10) == 100)
    }

    /// Without usable timestamps on either side there is no guess to make — the
    /// operator aligns by hand instead of being handed a fabricated offset.
    @Test func test_wall_clock_guess_is_absent_without_timestamps() {
        // `SessionMetadata.datetimeUtc` is 0 when the log carries no parseable date.
        #expect(VideoSyncModel.autoOffset(sessionStartEpoch: 0, videoStartEpoch: 1_000_000) == nil)
        #expect(VideoSyncModel.autoOffset(sessionStartEpoch: 1_000_000, videoStartEpoch: 0) == nil)
        #expect(VideoSyncModel.autoOffset(sessionStartEpoch: .nan, videoStartEpoch: 1_000_000) == nil)
        #expect(VideoSyncModel.autoOffset(sessionStartEpoch: 1_000_000, videoStartEpoch: .infinity) == nil)
        #expect(VideoSyncModel.autoOffset(sessionStartEpoch: -5, videoStartEpoch: 1_000_000) == nil)
    }
}
