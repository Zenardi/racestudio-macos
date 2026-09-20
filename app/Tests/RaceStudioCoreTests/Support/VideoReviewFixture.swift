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

    /// The split id of the `index`-th split (0-based) in lap 0.
    static func splitID(_ index: Int) -> Int {
        timeline().laps[0].sectors[index].splitID
    }
}
