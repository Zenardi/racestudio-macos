import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `TelemetrySeries` (issue 9.9): one channel's samples as contiguous
/// `times`/`values` arrays, read at any session time `t` by linear interpolation
/// (continuous channels) or step-hold (gear), with `nil` — never a fabricated
/// value — inside a sample gap, before the first sample and after the last.
///
/// The hint cursor is what lets the exporter sample 30–60 frames a second in
/// amortized O(1); the property tests prove it never changes an answer.
@Suite struct TelemetrySeriesTests {

    // MARK: - Fixtures

    /// Four samples 0.1 s apart: 10 → 20 → 40 → 40.
    private func even(_ mode: InterpolationMode = .linear) -> TelemetrySeries {
        TelemetrySeries(times: [1.0, 1.1, 1.2, 1.3], values: [10, 20, 40, 40], mode: mode)
    }

    // MARK: - Linear

    /// Given a linear series, when it is read exactly on a sample instant, then
    /// the sample's own value comes back unchanged.
    @Test func test_linear_is_exact_at_sample_instants() {
        let series = even()

        #expect(series.value(at: 1.0) == 10)
        #expect(series.value(at: 1.1) == 20)
        #expect(series.value(at: 1.3) == 40, "the last instant is inside the series")
    }

    /// Given a linear series, when it is read between two samples, then the
    /// value is the straight line between them.
    @Test func test_linear_interpolates_between_samples() throws {
        let series = even()

        let midpoint = try #require(series.value(at: 1.15))
        let quarter = try #require(series.value(at: 1.025))
        #expect(abs(midpoint - 30) < 1e-9)
        #expect(abs(quarter - 12.5) < 1e-9)
    }

    // MARK: - Step-hold

    /// Given a step-held series (gear), when it is read between two samples,
    /// then it keeps the earlier sample's value until the next one arrives.
    @Test func test_step_hold_keeps_the_previous_sample() {
        let gear = TelemetrySeries(times: [0, 1, 2], values: [2, 3, 4], mode: .stepHold, maxGap: 5)

        #expect(gear.value(at: 0.99) == 2, "no blend towards the next gear")
        #expect(gear.value(at: 1) == 3, "the new gear holds from its own instant")
        #expect(gear.value(at: 1.5) == 3)
    }

    // MARK: - Gaps and range

    /// Given two samples further apart than the gap threshold, when `t` falls
    /// between them, then there is no value — a gap is never bridged.
    @Test func test_a_gap_longer_than_the_threshold_reads_nil() {
        let series = TelemetrySeries(times: [0, 0.1, 0.8, 0.9], values: [1, 2, 3, 4])

        #expect(series.value(at: 0.45) == nil, "0.7 s gap > 0.5 s")
        #expect(series.value(at: 0.1) == 2, "the sample before the gap still reads")
        #expect(series.value(at: 0.8) == 3, "the sample after the gap still reads")
    }

    /// Given samples exactly one threshold apart, when `t` falls between them,
    /// then they still interpolate — only a gap *longer* than the threshold is cut.
    @Test func test_a_gap_equal_to_the_threshold_still_interpolates() {
        let series = TelemetrySeries(times: [0, 0.5], values: [0, 10])

        #expect(series.value(at: 0.25) == 5)
    }

    /// Given a step-held series, when `t` lies in a gap, then it is `nil` too: a
    /// held gear is not carried across missing data.
    @Test func test_step_hold_respects_the_gap_threshold() {
        let gear = TelemetrySeries(times: [0, 2], values: [3, 4], mode: .stepHold)

        #expect(gear.value(at: 1) == nil)
    }

    /// Given a series, when `t` is before its first or after its last sample,
    /// then the value is `nil` rather than a clamped endpoint.
    @Test func test_outside_the_sampled_range_reads_nil() {
        let series = even()

        #expect(series.value(at: 0.999) == nil)
        #expect(series.value(at: 1.301) == nil)
    }

    /// An empty series, a non-finite `t`, or a non-finite sample value has no
    /// value to report.
    @Test func test_empty_series_and_non_finite_inputs_read_nil() {
        let empty = TelemetrySeries(times: [], values: [])
        let holed = TelemetrySeries(times: [0, 0.1, 0.2], values: [1, .nan, 3])

        #expect(empty.value(at: 0) == nil)
        #expect(empty.isEmpty)
        #expect(even().value(at: .nan) == nil)
        #expect(even().value(at: .infinity) == nil)
        #expect(holed.value(at: 0.1) == nil, "a NaN sample is a hole, not a number")
        #expect(holed.value(at: 0.05) == nil, "interpolating into a hole is a hole")
    }

    /// The covered time range is the first to the last kept sample.
    @Test func test_time_range_spans_the_kept_samples() {
        #expect(even().timeRange == 1.0...1.3)
        #expect(TelemetrySeries(times: [], values: []).timeRange == nil)
    }

    // MARK: - Sanitising

    /// Given samples whose times step backwards (a single out-of-order record,
    /// left as logged by the decoder) or repeat, when the series is built, then
    /// those samples are dropped so the times stay strictly increasing and
    /// searchable; mismatched array lengths are truncated to the shorter.
    @Test func test_out_of_order_and_repeated_times_are_dropped() {
        let series = TelemetrySeries(times: [0, 0.1, 0.05, 0.1, 0.2, .nan, 0.3, 0.4],
                                     values: [0, 1, 99, 98, 2, 97, 3])

        #expect(series.times == [0, 0.1, 0.2, 0.3])
        #expect(series.values == [0, 1, 2, 3])
        #expect(TelemetrySeries(times: [0, 0.2, 0.1], values: [1, 2, 3]).times == [0, 0.2],
                "equal-length arrays are sanitised too")
    }

    // MARK: - Hint cursor

    /// Property: for random series (with gaps, holes and both modes) and both
    /// monotone and shuffled query sequences, reading with a carried hint gives
    /// exactly the answer a fresh random read gives at every instant.
    @Test(arguments: [UInt64(1), 7, 42, 2026])
    func test_hint_sampling_equals_random_sampling(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for mode in [InterpolationMode.linear, .stepHold] {
            let series = randomSeries(&rng, mode: mode)
            let monotone = (0..<600).map { Double($0) * 0.0333 - 1 }
            let shuffled = monotone.shuffled(using: &rng)

            for queries in [monotone, shuffled] {
                var hint = 0
                for t in queries {
                    #expect(series.value(at: t, hint: &hint) == series.value(at: t),
                            "seed \(seed) mode \(mode) t \(t)")
                }
            }
        }
    }

    /// A stale or out-of-range hint (from another series, or a backwards seek)
    /// is recovered from rather than trusted.
    @Test func test_an_out_of_range_hint_is_ignored() {
        let series = even()
        var hint = 999

        #expect(series.value(at: 1.15, hint: &hint) == series.value(at: 1.15))
        hint = -5
        #expect(series.value(at: 1.2, hint: &hint) == 40)
    }

    /// Random strictly-increasing samples 20–900 ms apart (so some exceed the
    /// gap threshold), with the odd NaN value.
    private func randomSeries(_ rng: inout SeededGenerator, mode: InterpolationMode) -> TelemetrySeries {
        var times: [Double] = []
        var values: [Double] = []
        var t = Double.random(in: 0...1, using: &rng)
        while t < 19 {
            times.append(t)
            values.append(Int.random(in: 0..<40, using: &rng) == 0 ? .nan : Double.random(in: -50...50, using: &rng))
            t += Double.random(in: 0.02...0.9, using: &rng)
        }
        return TelemetrySeries(times: times, values: values, mode: mode)
    }
}
