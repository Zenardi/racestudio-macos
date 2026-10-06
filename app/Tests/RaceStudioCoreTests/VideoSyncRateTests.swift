import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 clock **rate** on `VideoSyncModel`: the mapping
/// becomes `videoTime = cursorTime × rate + offset`, with the exact inverse
/// `(videoTime − offset) / rate`, so a camera clock that runs slightly fast or
/// slow against the logger no longer drifts across a long stint.
///
/// `rate == 1` must reproduce the 9.5/9.6 mapping exactly — those suites
/// (`VideoSyncModelTests`, `VideoSyncWindowTests`) stay untouched and green; the
/// cases here pin that equivalence explicitly as well.
@Suite struct VideoSyncRateTests {

    /// A 1000 s video whose clock runs 0.1% fast and leads the session by 5 s.
    private func drifting() -> VideoSyncModel {
        VideoSyncModel(videoDuration: 1_000, offset: 5, rate: 1.001)
    }

    // MARK: - rate == 1 is the 9.5/9.6 mapping

    /// A model built without a rate runs at `1`, and is the same value as one
    /// built with an explicit `rate: 1`.
    @Test func test_rate_defaults_to_one() {
        #expect(VideoSyncModel(videoDuration: 120, offset: 12.5).rate == 1)
        #expect(VideoSyncModel(videoDuration: 120, offset: 12.5)
                == VideoSyncModel(videoDuration: 120, offset: 12.5, rate: 1))
    }

    /// At `rate == 1` every forward and inverse mapping is bit-identical to the
    /// plain `cursorTime + offset` of 9.5 — no rounding introduced by the rate.
    @Test func test_unit_rate_reproduces_the_offset_only_mapping() {
        let sync = VideoSyncModel(videoDuration: 120, offset: 12.5, rate: 1)

        for cursor in [-30.0, 0, 0.1, 7.3, 30, 73.25, 107.5, 500] {
            #expect(sync.videoTime(forCursorTime: cursor) == min(max(cursor + 12.5, 0), 120))
        }
        for playhead in [-5.0, 0, 0.1, 42.5, 119.9, 120, 999] {
            #expect(sync.cursorTime(forVideoTime: playhead) == min(max(playhead, 0), 120) - 12.5)
        }
    }

    // MARK: - The rate mapping

    /// The forward map scales session time by the rate before adding the offset.
    @Test func test_cursor_time_is_scaled_by_the_rate() {
        #expect(abs(drifting().videoTime(forCursorTime: 100) - 105.1) < 1e-9)
    }

    /// The inverse subtracts the offset, then divides by the rate.
    @Test func test_video_time_maps_back_through_the_rate() {
        #expect(abs(drifting().cursorTime(forVideoTime: 105.1) - 100) < 1e-9)
    }

    /// Forward then inverse is the identity within 1e-9 anywhere inside bounds,
    /// for rates at both ends of the accepted band.
    @Test(arguments: [0.995, 0.9999, 1.0001, 1.005])
    func test_round_trip_is_exact_with_a_rate(rate: Double) {
        let sync = VideoSyncModel(videoDuration: 1_000, offset: -3.25, rate: rate)

        for cursor in [3.5, 10, 123.456, 600, 990] {
            let back = sync.cursorTime(forVideoTime: sync.videoTime(forCursorTime: cursor))
            #expect(abs(back - cursor) < 1e-9, "round trip at \(cursor)")
        }
    }

    /// The scaled seek target is still clamped to the footage.
    @Test func test_scaled_seek_is_clamped_to_the_footage() {
        let sync = drifting()

        #expect(sync.videoTime(forCursorTime: 5_000) == 1_000)
        #expect(sync.videoTime(forCursorTime: -5_000) == 0)
    }

    /// Re-offsetting keeps the rate: a trim after a two-point sync must not
    /// silently throw the drift correction away.
    @Test func test_reoffsetting_keeps_the_rate() {
        #expect(drifting().withOffset(9).rate == 1.001)
        #expect(drifting().withOffset(9).offset == 9)
    }

    // MARK: - Windows, coverage and anchoring honour the rate

    /// A section's window is scaled at both ends.
    @Test func test_window_is_scaled_by_the_rate() {
        let window = drifting().videoRange(for: SessionTimeSpan(start: 100, end: 200))

        #expect(abs(window.lowerBound - 105.1) < 1e-9)
        #expect(abs(window.upperBound - 205.2) < 1e-9)
    }

    /// Coverage reads the scaled projection: a section the offset alone would
    /// keep inside the footage can run off its end once the rate stretches it.
    @Test func test_coverage_reads_the_scaled_projection() {
        let fast = VideoSyncModel(videoDuration: 100, offset: 0, rate: 1.005)
        let span = SessionTimeSpan(start: 90, end: 99.8) // ends at 100.299 once scaled

        #expect(VideoSyncModel(videoDuration: 100).coverage(of: span) == .full)
        #expect(fast.coverage(of: span) == .partial)
    }

    /// Anchoring a section start to a frame is still exact with a rate: that
    /// start lands on the playhead, and the rate is kept.
    @Test func test_track_anchor_is_exact_with_a_rate() {
        let anchored = drifting().aligned(sessionTime: 300, toPlayhead: 420)

        #expect(abs(anchored.videoTime(forCursorTime: 300) - 420) < 1e-9)
        #expect(anchored.rate == 1.001)
    }

    /// The ±60 s cursor nudge is exact with a rate too, and keeps the rate.
    @Test func test_cursor_nudge_is_exact_with_a_rate() {
        let nudged = drifting().aligned(playhead: 50, toCursorTime: 30)

        #expect(abs(nudged.videoTime(forCursorTime: 30) - 50) < 1e-9)
        #expect(nudged.rate == 1.001)
    }

    // MARK: - Sanitizing

    /// A non-finite, zero or negative rate can never reach the mapping — it would
    /// divide by zero or run the footage backwards — so it falls back to `1`.
    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -1, -0.5])
    func test_unusable_rate_is_sanitized_to_one(rate: Double) {
        #expect(VideoSyncModel(videoDuration: 60, offset: 2, rate: rate).rate == 1)
    }
}
