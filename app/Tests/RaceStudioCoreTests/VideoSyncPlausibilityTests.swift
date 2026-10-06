import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 **plausible** wall-clock offset: the file-date guess
/// is only proposed when, once applied, the footage would actually overlap the
/// session by at least ``VideoSyncModel/minimumPlausibleOverlap``.
///
/// A re-exported, trimmed or copied file carries its *export* time as its
/// creation date — in the real case two days after the session — and the blind
/// 9.6 guess then put every lap "outside the footage". The raw
/// ``VideoSyncModel/autoOffset(sessionStartEpoch:videoStartEpoch:)`` stays (and is
/// covered by `VideoSyncWindowTests`); this is the gate in front of it.
@Suite struct VideoSyncPlausibilityTests {

    /// Ten minutes of footage against a ten-minute session.
    private let footage = VideoSyncModel(videoDuration: 600)
    private let sessionStart = 1_000_000.0
    private let sessionLength = 600.0

    private func plausible(videoStart: Double, sync: VideoSyncModel? = nil,
                           sessionDuration: Double? = nil) -> Double? {
        (sync ?? footage).plausibleAutoOffset(sessionStartEpoch: sessionStart,
                                              videoStartEpoch: videoStart,
                                              sessionDuration: sessionDuration ?? sessionLength)
    }

    // MARK: - Implausible dates are refused

    /// A file re-exported two days after the session: the guess would put the
    /// whole session two days before the footage, so nothing is proposed.
    @Test func test_a_two_day_gap_is_implausible() {
        #expect(plausible(videoStart: sessionStart + 172_800) == nil)
    }

    /// The mirror case — footage stamped long before the session — is refused too.
    @Test func test_footage_long_before_the_session_is_implausible() {
        #expect(plausible(videoStart: sessionStart - 172_800) == nil)
    }

    // MARK: - Plausible dates are proposed

    /// A camera started 30 s before the logger overlaps almost all of the session:
    /// the offset is proposed unchanged.
    @Test func test_an_overlapping_date_proposes_the_offset() {
        #expect(plausible(videoStart: sessionStart - 30) == 30)
    }

    /// A camera started after the logger (a negative offset) is just as usable.
    @Test func test_a_camera_started_late_is_still_plausible() {
        #expect(plausible(videoStart: sessionStart + 45) == -45)
    }

    // MARK: - Exact boundaries

    /// The session's end overlapping the footage's start by exactly 1 s is
    /// plausible; half a second is not.
    @Test func test_exactly_one_second_of_overlap_at_the_footage_start_is_plausible() {
        #expect(plausible(videoStart: sessionStart + 599) == -599)
        #expect(plausible(videoStart: sessionStart + 599.5) == nil)
    }

    /// The session's start overlapping the footage's end by exactly 1 s is
    /// plausible; half a second is not.
    @Test func test_exactly_one_second_of_overlap_at_the_footage_end_is_plausible() {
        #expect(plausible(videoStart: sessionStart - 599) == 599)
        #expect(plausible(videoStart: sessionStart - 599.5) == nil)
    }

    /// Spans that only touch (zero overlap) are not an alignment.
    @Test func test_touching_spans_are_implausible() {
        #expect(plausible(videoStart: sessionStart + 600) == nil)
        #expect(plausible(videoStart: sessionStart - 600) == nil)
    }

    /// The test reads the mapped session span, so a fast camera clock that
    /// stretches the session past the footage's start makes an otherwise
    /// touching date plausible. (`1 + 5/1024` is exact in binary.)
    @Test func test_plausibility_honours_the_rate() {
        let fast = VideoSyncModel(videoDuration: 600, rate: 1 + 5.0 / 1_024) // session maps to 602.9296875 s
        let videoStart = sessionStart + 601.9296875

        #expect(plausible(videoStart: videoStart, sync: fast) == -601.9296875)
        #expect(plausible(videoStart: videoStart) == nil, "at rate 1 the session ends before the footage")
    }

    // MARK: - Degenerate input

    /// Without both clocks there is nothing to test — the raw guess is refused.
    @Test func test_a_missing_clock_is_refused() {
        #expect(footage.plausibleAutoOffset(sessionStartEpoch: 0, videoStartEpoch: sessionStart,
                                            sessionDuration: 600) == nil)
        #expect(footage.plausibleAutoOffset(sessionStartEpoch: sessionStart, videoStartEpoch: .nan,
                                            sessionDuration: 600) == nil)
    }

    /// A zero-length video can overlap nothing.
    @Test func test_a_zero_length_video_is_refused() {
        #expect(plausible(videoStart: sessionStart - 30, sync: VideoSyncModel(videoDuration: 0)) == nil)
    }

    /// An unknown, empty or non-finite session length cannot be tested against
    /// the footage, so no guess is proposed rather than an unchecked one.
    @Test(arguments: [0.0, -10, .nan, .infinity])
    func test_an_unusable_session_length_is_refused(duration: Double) {
        #expect(plausible(videoStart: sessionStart - 30, sessionDuration: duration) == nil)
    }
}
