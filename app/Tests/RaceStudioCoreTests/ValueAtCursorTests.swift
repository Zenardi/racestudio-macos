import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ValueAtCursor` (issue 4.4) — value-at-cursor interpolation.
@Suite struct ValueAtCursorTests {

    private let series = ChannelSeries(xs: [10, 20, 30], values: [1, 2, 3])

    @Test func test_value_interpolates_between_samples() {
        let readout = ValueAtCursor.value(at: 15, in: series)
        #expect(readout.value == 1.5)
        #expect(readout.extrapolated == false)

        // A non-uniform position interpolates proportionally.
        let quarter = ValueAtCursor.value(at: 22.5, in: series)
        #expect(quarter.value == 2.25)
    }

    @Test func test_value_at_exact_sample() {
        let interior = ValueAtCursor.value(at: 20, in: series)
        #expect(interior.value == 2)
        #expect(interior.extrapolated == false)

        // Endpoints are exact, not extrapolated.
        #expect(ValueAtCursor.value(at: 10, in: series).extrapolated == false)
        #expect(ValueAtCursor.value(at: 30, in: series).value == 3)
        #expect(ValueAtCursor.value(at: 30, in: series).extrapolated == false)
    }

    @Test func test_value_before_first_clamps_and_flags_extrapolated() {
        let before = ValueAtCursor.value(at: 5, in: series)
        #expect(before.value == 1, "clamps to the first value")
        #expect(before.extrapolated == true)

        let after = ValueAtCursor.value(at: 35, in: series)
        #expect(after.value == 3, "clamps to the last value")
        #expect(after.extrapolated == true)
    }

    @Test func test_value_on_empty_or_nonfinite_has_no_value() {
        #expect(ValueAtCursor.value(at: 10, in: ChannelSeries(xs: [], values: [])).value == nil)
        #expect(ValueAtCursor.value(at: .nan, in: series).value == nil)
        #expect(ValueAtCursor.value(at: .infinity, in: series).value == nil)
    }

    @Test func test_single_sample_series() {
        let one = ChannelSeries(xs: [10], values: [7])
        #expect(ValueAtCursor.value(at: 10, in: one).value == 7)
        #expect(ValueAtCursor.value(at: 10, in: one).extrapolated == false)
        #expect(ValueAtCursor.value(at: 5, in: one).extrapolated == true)
        #expect(ValueAtCursor.value(at: 99, in: one).value == 7)
    }
}
