import Testing
import CoreGraphics
@testable import RaceStudioCore

/// Tests for `ScatterModel` (issue 4.5) — channel-vs-channel pairing.
@Suite struct ScatterModelTests {

    @Test func test_scatter_drops_nan_pairs() {
        // x and y are aligned by index on a common basis; a sample survives only
        // when BOTH channels are finite at that index.
        let x = ChannelSeries(xs: [0, 1, 2, 3], values: [10, .nan, 30, 40])
        let y = ChannelSeries(xs: [0, 1, 2, 3], values: [1, 2, .nan, 4])
        // index 1 dropped (x NaN), index 2 dropped (y NaN); 0 and 3 survive.
        #expect(ScatterModel.points(x: x, y: y) == [CGPoint(x: 10, y: 1), CGPoint(x: 40, y: 4)])
    }

    @Test func test_scatter_pairs_by_index() {
        let x = ChannelSeries(xs: [0, 1, 2], values: [5, 6, 7])
        let y = ChannelSeries(xs: [0, 1, 2], values: [50, 60, 70])
        #expect(ScatterModel.points(x: x, y: y) ==
                [CGPoint(x: 5, y: 50), CGPoint(x: 6, y: 60), CGPoint(x: 7, y: 70)])
    }

    @Test func test_scatter_windows_to_subset() {
        // Only samples whose basis lies inside the window survive.
        let x = ChannelSeries(xs: [0, 10, 20, 30], values: [1, 2, 3, 4])
        let y = ChannelSeries(xs: [0, 10, 20, 30], values: [9, 8, 7, 6])
        #expect(ScatterModel.points(x: x, y: y, window: 10...20) ==
                [CGPoint(x: 2, y: 8), CGPoint(x: 3, y: 7)])
    }

    @Test func test_scatter_handles_ragged_lengths() {
        // The shorter series bounds the pairing; no out-of-range access.
        let x = ChannelSeries(xs: [0, 1, 2, 3], values: [1, 2, 3, 4])
        let y = ChannelSeries(xs: [0, 1], values: [10, 20])
        #expect(ScatterModel.points(x: x, y: y) == [CGPoint(x: 1, y: 10), CGPoint(x: 2, y: 20)])
    }

    @Test func test_scatter_empty_when_window_excludes_all() {
        let x = ChannelSeries(xs: [0, 1], values: [1, 2])
        let y = ChannelSeries(xs: [0, 1], values: [3, 4])
        #expect(ScatterModel.points(x: x, y: y, window: 100...200).isEmpty)
    }
}
