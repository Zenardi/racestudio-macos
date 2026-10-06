import Foundation
@testable import RaceStudioCore

/// The two-lap, two-sector timeline the issue 9.6 video-review suites share:
/// lap 0 = 10…18 s (S1 10…13, S2 13…18), lap 1 = 18…24 s (S1 18…20, S2 20…24).
/// Shared so the navigation and selection suites cannot drift apart on the very
/// fixture they both reason about.
enum VideoReviewFixture {

    static func timeline() -> LapSectorTimeline {
        LapSectorTimeline.make(
            laps: [Lap(index: 0, startTimeS: 10, durationS: 8, endTimeS: 18),
                   Lap(index: 1, startTimeS: 18, durationS: 6, endTimeS: 24)],
            segments: [LapSegments(lap: LapID(0), baseTimes: [1, 2, 2, 3]),
                       LapSegments(lap: LapID(1), baseTimes: [1, 1, 2, 2])],
            layout: SplitLayout.even(base: 4, count: 2))
    }

    /// A model over that timeline with 120 s of footage aligned 1:1 to the session.
    @MainActor
    static func model() -> VideoReviewModel {
        VideoReviewModel(timeline: timeline(), sync: VideoSyncModel(videoDuration: 120))
    }

    /// Sixteen one-minute laps from session time 0 (lap `n` = `60n…60(n+1)` s),
    /// with no sectors — the issue 9.7 sync suites' stint: long enough for two
    /// lap-start anchors to sit well over ten seconds apart.
    static func sixteenLaps() -> LapSectorTimeline {
        LapSectorTimeline(laps: (0..<16).map { index in
            LapSpan(lap: LapID(index),
                    span: SessionTimeSpan(start: Double(index) * 60, end: Double(index + 1) * 60),
                    sectors: [])
        })
    }

    /// A review over ``sixteenLaps()`` with `videoDuration` seconds of footage,
    /// not yet aligned.
    @MainActor
    static func stint(videoDuration: Double = 1_000) -> VideoReviewModel {
        VideoReviewModel(timeline: sixteenLaps(), sync: VideoSyncModel(videoDuration: videoDuration))
    }

    /// The split id of the `index`-th split (0-based) in lap 0.
    static func splitID(_ index: Int) -> Int {
        timeline().laps[0].sectors[index].splitID
    }
}
