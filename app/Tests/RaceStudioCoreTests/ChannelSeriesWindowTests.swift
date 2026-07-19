import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelSeries.windowed(from:through:)` (issue 8.5) — scoping a
/// channel's samples to a single lap's time range so a cursor outside that range
/// reads as extrapolated (greyed) in the measures panel.
@Suite struct ChannelSeriesWindowTests {

    private let series = ChannelSeries(xs: [0, 1, 2, 3, 4, 5], values: [0, 10, 20, 30, 40, 50])

    @Test func test_window_keeps_only_samples_within_the_inclusive_range() {
        let window = series.windowed(from: 1, through: 3)
        #expect(window.xs == [1, 2, 3])
        #expect(window.values == [10, 20, 30])
    }

    @Test func test_window_endpoints_are_inclusive() {
        let window = series.windowed(from: 0, through: 2)
        #expect(window.xs == [0, 1, 2], "the lower and upper bounds are both included")
        #expect(window.values == [0, 10, 20])
    }

    @Test func test_window_covering_everything_returns_the_whole_series() {
        let window = series.windowed(from: -1, through: 100)
        #expect(window.xs == series.xs)
        #expect(window.values == series.values)
    }

    @Test func test_window_outside_the_samples_is_empty() {
        let window = series.windowed(from: 10, through: 20)
        #expect(window.xs.isEmpty)
        #expect(window.values.isEmpty)
    }

    @Test func test_inverted_window_is_empty() {
        // A degenerate lap (end before start) scopes to nothing rather than trapping.
        let window = series.windowed(from: 4, through: 1)
        #expect(window.xs.isEmpty)
        #expect(window.values.isEmpty)
    }

    @Test func test_window_stays_index_aligned() {
        // The trim invariant holds: xs and values keep the same length.
        let window = series.windowed(from: 2, through: 4)
        #expect(window.xs.count == window.values.count)
        #expect(window.values == [20, 30, 40])
    }
}
