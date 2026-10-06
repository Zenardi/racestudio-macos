import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `TwoPointSync` (issue 9.7): solving both the sync **offset** and the
/// clock **rate** from two anchors — the session time of two lap starts and the
/// video frames where the kart crosses the line on each — so a camera clock that
/// drifts against the logger stays aligned across a long stint.
@Suite struct TwoPointSyncTests {

    /// The anchors a camera running 100 ppm fast, leading by 12.5 s, produces at
    /// session times `sessionA` and `sessionB`.
    private func anchors(sessionA: Double = 100, sessionB: Double = 700,
                         offset: Double = 12.5, rate: Double = 1.0001) -> (SyncAnchor, SyncAnchor) {
        (SyncAnchor(sessionTime: sessionA, videoTime: sessionA * rate + offset),
         SyncAnchor(sessionTime: sessionB, videoTime: sessionB * rate + offset))
    }

    private func solved(_ pair: (SyncAnchor, SyncAnchor)) throws -> TwoPointSync.Solution {
        try TwoPointSync.solve(anchorA: pair.0, anchorB: pair.1).get()
    }

    // MARK: - Solving

    /// Given two anchors from a known offset and rate, both are recovered.
    @Test func test_solve_recovers_a_known_offset_and_rate() throws {
        let solution = try solved(anchors())

        #expect(abs(solution.rate - 1.0001) < 1e-12)
        #expect(abs(solution.offset - 12.5) < 1e-9)
    }

    /// The solved mapping lands both anchors exactly on their frames.
    @Test func test_both_anchors_map_exactly() throws {
        let pair = anchors()
        let solution = try solved(pair)
        let sync = VideoSyncModel(videoDuration: 1_000, offset: solution.offset, rate: solution.rate)

        #expect(abs(sync.videoTime(forCursorTime: pair.0.sessionTime) - pair.0.videoTime) < 1e-9)
        #expect(abs(sync.videoTime(forCursorTime: pair.1.sessionTime) - pair.1.videoTime) < 1e-9)
    }

    /// The order the anchors are given in does not matter.
    @Test func test_reversed_anchors_give_the_same_solution() throws {
        let pair = anchors()
        let forward = try solved(pair)
        let reversed = try solved((pair.1, pair.0))

        #expect(abs(forward.rate - reversed.rate) < 1e-12)
        #expect(abs(forward.offset - reversed.offset) < 1e-9)
    }

    /// Clocks that agree solve to exactly the offset-only mapping.
    @Test func test_matching_clocks_solve_to_unit_rate() throws {
        let solution = try solved(anchors(offset: -40, rate: 1))

        #expect(solution.rate == 1)
        #expect(solution.offset == -40)
    }

    // MARK: - Rejections

    /// Anchors under ten seconds apart in session time cannot pin a rate.
    @Test func test_anchors_too_close_are_rejected() {
        let pair = anchors(sessionA: 100, sessionB: 109.5)

        #expect(TwoPointSync.solve(anchorA: pair.0, anchorB: pair.1) == .failure(.anchorsTooClose))
    }

    /// Exactly ten seconds apart is enough.
    @Test func test_anchors_exactly_ten_seconds_apart_are_accepted() throws {
        #expect(abs(try solved(anchors(sessionA: 100, sessionB: 110)).rate - 1.0001) < 1e-9)
    }

    /// Two anchors on the same lap start are the degenerate too-close case.
    @Test func test_identical_anchors_are_rejected() {
        let anchor = SyncAnchor(sessionTime: 50, videoTime: 60)

        #expect(TwoPointSync.solve(anchorA: anchor, anchorB: anchor) == .failure(.anchorsTooClose))
    }

    /// A rate beyond ±0.5% is a mis-anchor, not a camera clock: it is rejected
    /// and the implied rate is reported.
    @Test func test_rate_out_of_bounds_is_rejected_with_the_rate() {
        let fast = SyncAnchor(sessionTime: 200, videoTime: 202)
        let origin = SyncAnchor(sessionTime: 0, videoTime: 0)

        #expect(TwoPointSync.solve(anchorA: origin, anchorB: fast) == .failure(.rateOutOfBounds(1.01)))
    }

    /// The bounds themselves are accepted; just past them is not.
    @Test func test_rate_bounds_are_inclusive() throws {
        let origin = SyncAnchor(sessionTime: 0, videoTime: 0)

        #expect(try TwoPointSync.solve(anchorA: origin, anchorB: SyncAnchor(sessionTime: 200, videoTime: 201))
            .get().rate == 1.005)
        #expect(try TwoPointSync.solve(anchorA: origin, anchorB: SyncAnchor(sessionTime: 200, videoTime: 199))
            .get().rate == 0.995)
        #expect(TwoPointSync.solve(anchorA: origin, anchorB: SyncAnchor(sessionTime: 200, videoTime: 201.01))
            == .failure(.rateOutOfBounds(201.01 / 200)))
    }

    /// Anchors whose frames run in the opposite order to their laps imply a
    /// negative rate — always a mis-anchor.
    @Test func test_crossed_anchors_are_rejected() {
        let early = SyncAnchor(sessionTime: 100, videoTime: 500)
        let late = SyncAnchor(sessionTime: 400, videoTime: 200)

        #expect(TwoPointSync.solve(anchorA: early, anchorB: late) == .failure(.rateOutOfBounds(-1)))
    }

    /// Any non-finite input is rejected before it can reach the mapping.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func test_non_finite_input_is_rejected(bad: Double) {
        let good = SyncAnchor(sessionTime: 100, videoTime: 110)

        #expect(TwoPointSync.solve(anchorA: SyncAnchor(sessionTime: bad, videoTime: 1), anchorB: good)
                == .failure(.nonFinite))
        #expect(TwoPointSync.solve(anchorA: good, anchorB: SyncAnchor(sessionTime: 500, videoTime: bad))
                == .failure(.nonFinite))
    }
}
