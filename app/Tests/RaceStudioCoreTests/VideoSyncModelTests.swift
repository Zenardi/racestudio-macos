import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `VideoSyncModel` (parity gap 9.5, issue #140): the pure time-mapping
/// between the analysis cursor's session time and an imported video's playhead.
/// The map is `videoTime = clamp(cursorTime + offset, 0...duration)` with the
/// exact inverse for the reverse direction — no AVKit, all value-type math, so
/// every acceptance behaviour is demonstrable here rather than in the shell view.
@Suite struct VideoSyncModelTests {

    /// A 120 s video synced so the session cursor leads the footage by 12.5 s.
    private func synced() -> VideoSyncModel {
        VideoSyncModel(videoDuration: 120, offset: 12.5)
    }

    // MARK: - Named acceptance behaviours

    /// Given an imported video and a sync offset, when the cursor moves to time t,
    /// the video seeks to `t + offset`.
    @Test func test_cursor_time_maps_to_video_time_with_offset() {
        let sync = synced()
        #expect(sync.videoTime(forCursorTime: 30) == 42.5)
        #expect(sync.videoTime(forCursorTime: 0) == 12.5, "the offset applies at the origin too")
    }

    /// Given the video is playing, when its playhead is at v, the linked cursor
    /// time is the exact inverse `v - offset`, and a forward→back round-trip within
    /// bounds recovers the original cursor time.
    @Test func test_video_time_maps_back_to_cursor() {
        let sync = synced()
        #expect(sync.cursorTime(forVideoTime: 42.5) == 30)

        let cursor = 73.25
        let roundTrip = sync.cursorTime(forVideoTime: sync.videoTime(forCursorTime: cursor))
        #expect(abs(roundTrip - cursor) < 1e-9, "forward then inverse is identity inside bounds")
    }

    /// A seek target is clamped to `[0, duration]`: a cursor past the end pins to
    /// the last frame, one before the start pins to the first.
    @Test func test_seek_is_clamped_to_video_bounds() {
        let sync = synced() // duration 120, offset 12.5

        #expect(sync.videoTime(forCursorTime: 1_000) == 120, "past the end clamps to duration")
        #expect(sync.videoTime(forCursorTime: -1_000) == 0, "before the start clamps to zero")
        // A negative offset can push an early cursor below zero — still clamped.
        #expect(VideoSyncModel(videoDuration: 120, offset: -30).videoTime(forCursorTime: 10) == 0)
    }

    /// Editing the offset re-projects from the current offset only — it never
    /// accumulates. Editing to a value and back yields an identical mapping, and a
    /// chain of edits leaves the projection equal to `cursor + finalOffset`.
    @Test func test_offset_edit_reprojects_without_drift() {
        let sync = synced() // offset 12.5

        let edited = sync.withOffset(20)
        #expect(edited.videoTime(forCursorTime: 30) == 50, "re-projects from the new offset, not 42.5")

        // Editing to a new value and back reproduces the original mapping exactly.
        #expect(edited.withOffset(12.5) == sync, "offset edits carry no hidden state — no drift")

        // A long chain of edits still maps purely from the final offset.
        let churned = sync.withOffset(5).withOffset(-8).withOffset(100).withOffset(3.5)
        #expect(churned.videoTime(forCursorTime: 40) == 43.5)
    }

    /// A zero-length (or absent) video must never trap: bounds collapse to `0...0`,
    /// every seek pins to zero, and the inverse stays finite.
    @Test func test_zero_length_video_never_panics() {
        let empty = VideoSyncModel(videoDuration: 0, offset: 5)
        #expect(empty.isEmpty)
        #expect(empty.videoBounds == 0...0)
        #expect(empty.videoTime(forCursorTime: 42) == 0, "no room to seek into — pinned to zero")
        #expect(empty.videoTime(forCursorTime: -42) == 0)
        #expect(empty.cursorTime(forVideoTime: 999) == -5, "clamped playhead 0 minus the offset")
    }

    // MARK: - Construction & sanitizing (edge / negative paths)

    @Test func test_default_offset_is_zero() {
        let sync = VideoSyncModel(videoDuration: 60)
        #expect(sync.offset == 0)
        #expect(sync.videoTime(forCursorTime: 10) == 10)
    }

    @Test func test_negative_or_nonfinite_duration_is_sanitized_to_zero() {
        #expect(VideoSyncModel(videoDuration: -10).videoDuration == 0)
        #expect(VideoSyncModel(videoDuration: .nan).videoDuration == 0)
        #expect(VideoSyncModel(videoDuration: .infinity).videoDuration == 0)
        // A sanitized duration makes an empty, trap-free model.
        #expect(VideoSyncModel(videoDuration: .nan).isEmpty)
    }

    @Test func test_nonfinite_offset_is_sanitized_to_zero() {
        #expect(VideoSyncModel(videoDuration: 60, offset: .nan).offset == 0)
        #expect(VideoSyncModel(videoDuration: 60, offset: .infinity).offset == 0)
    }

    @Test func test_nonfinite_cursor_time_maps_to_zero() {
        let sync = synced()
        #expect(sync.videoTime(forCursorTime: .nan) == 0)
        #expect(sync.videoTime(forCursorTime: .infinity) == 0)
    }

    @Test func test_nonfinite_video_time_maps_to_negative_offset() {
        // A non-finite playhead is treated as the start of the video (0), so the
        // cursor resolves to `0 - offset` rather than propagating NaN.
        let sync = synced()
        #expect(sync.cursorTime(forVideoTime: .nan) == -12.5)
    }

    // MARK: - Derived geometry

    @Test func test_is_empty_reflects_zero_duration() {
        #expect(!VideoSyncModel(videoDuration: 0.001).isEmpty)
        #expect(VideoSyncModel(videoDuration: 0).isEmpty)
    }

    @Test func test_video_bounds_span_zero_to_duration() {
        #expect(VideoSyncModel(videoDuration: 90).videoBounds == 0...90)
    }

    @Test func test_equatable_by_duration_and_offset() {
        #expect(VideoSyncModel(videoDuration: 60, offset: 3) == VideoSyncModel(videoDuration: 60, offset: 3))
        #expect(VideoSyncModel(videoDuration: 60, offset: 3) != VideoSyncModel(videoDuration: 60, offset: 4))
        #expect(VideoSyncModel(videoDuration: 60, offset: 3) != VideoSyncModel(videoDuration: 61, offset: 3))
    }

    // MARK: - Direction gate (feedback-loop prevention)

    /// The two directions are mutually exclusive for either playback state, so the
    /// cursor↔playhead pair can never drive each other in a loop.
    @Test func test_seek_and_drive_gates_are_mutually_exclusive() {
        let sync = synced()
        for playing in [true, false] {
            #expect(!(sync.shouldSeek(whilePlaying: playing) && sync.shouldDriveCursor(whilePlaying: playing)),
                    "seek and drive must never both fire (playing=\(playing))")
        }
        // Paused → the cursor seeks the video; playing → the video drives the cursor.
        #expect(sync.shouldSeek(whilePlaying: false))
        #expect(sync.shouldDriveCursor(whilePlaying: true))
        #expect(!sync.shouldSeek(whilePlaying: true))
        #expect(!sync.shouldDriveCursor(whilePlaying: false))
    }

    @Test func test_empty_video_gates_off_both_directions() {
        let empty = VideoSyncModel(videoDuration: 0, offset: 5)
        for playing in [true, false] {
            #expect(!empty.shouldSeek(whilePlaying: playing))
            #expect(!empty.shouldDriveCursor(whilePlaying: playing))
        }
    }

    // MARK: - Align-to-cursor

    @Test func test_align_to_cursor_sets_offset_to_playhead_minus_cursor() {
        let aligned = synced().aligned(playhead: 20, toCursorTime: 5)
        #expect(aligned.offset == 15)
    }

    @Test func test_align_to_cursor_clamps_offset_into_range() {
        // A far-apart playhead/cursor would demand a 495 s offset — clamped to the
        // adjustable span so the UI slider never desyncs.
        let aligned = synced().aligned(playhead: 500, toCursorTime: 5)
        #expect(aligned.offset == VideoSyncModel.offsetRange.upperBound)
        let back = synced().aligned(playhead: 0, toCursorTime: 500)
        #expect(back.offset == VideoSyncModel.offsetRange.lowerBound)
    }

    @Test func test_align_to_cursor_ignores_nonfinite_inputs() {
        let sync = synced()
        #expect(sync.aligned(playhead: .nan, toCursorTime: 5) == sync)
        #expect(sync.aligned(playhead: 20, toCursorTime: .infinity) == sync)
    }
}
