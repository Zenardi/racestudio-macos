import Testing
@testable import RaceStudioCore

/// Tests for the plot display knobs (issue 8.12): the `PlotLineStyle` line-width /
/// dot-size clamping, snap-to-lap-boundaries constraint, and the local-time lap
/// alignment offsets + trace time-shift.
@Suite struct PlotDisplayTests {

    // MARK: - Line / dot style

    @Test func test_line_style_defaults_to_a_visible_hairline_with_no_dots() {
        let style = PlotLineStyle()
        #expect(style.lineWidth == 1.5)
        #expect(style.dotSize == 0)
        #expect(!style.showsDots)
    }

    @Test func test_line_style_clamps_width_into_the_drawable_range() {
        #expect(PlotLineStyle(lineWidth: 0).lineWidth == PlotLineStyle.minLineWidth)
        #expect(PlotLineStyle(lineWidth: -3).lineWidth == PlotLineStyle.minLineWidth)
        #expect(PlotLineStyle(lineWidth: 999).lineWidth == PlotLineStyle.maxLineWidth)
        #expect(PlotLineStyle(lineWidth: .nan).lineWidth == PlotLineStyle.minLineWidth,
                "a non-finite width falls back to the floor, never traps")
    }

    @Test func test_line_style_clamps_dot_size_and_reports_visibility() {
        #expect(PlotLineStyle(dotSize: -1).dotSize == 0)
        #expect(PlotLineStyle(dotSize: 999).dotSize == PlotLineStyle.maxDotSize)
        #expect(PlotLineStyle(dotSize: 4).showsDots)
        #expect(!PlotLineStyle(dotSize: 0).showsDots)
    }

    // MARK: - Snap to lap boundaries

    private let boundaries = [0.0, 100.0, 200.0, 300.0]

    @Test func test_snap_pulls_both_edges_onto_the_nearest_lap_boundaries() {
        // A window from mid-lap-1 to mid-lap-2 snaps out to whole laps [100, 300].
        let snapped = snapToLapBoundaries(140...260, boundaries: boundaries)
        #expect(snapped == 100...300)
    }

    @Test func test_snap_frames_a_whole_lap_when_both_edges_land_on_one_boundary() {
        // A tiny window hugging the 200 boundary snaps to the whole lap [200, 300].
        let snapped = snapToLapBoundaries(198...202, boundaries: boundaries)
        #expect(snapped == 200...300)
    }

    @Test func test_snap_frames_the_last_lap_when_it_collapses_on_the_final_boundary() {
        let snapped = snapToLapBoundaries(295...305, boundaries: boundaries)
        #expect(snapped == 200...300, "the final boundary frames the preceding whole lap")
    }

    @Test func test_snap_is_a_noop_without_at_least_two_boundaries() {
        #expect(snapToLapBoundaries(10...20, boundaries: []) == 10...20)
        #expect(snapToLapBoundaries(10...20, boundaries: [100]) == 10...20)
    }

    @Test func test_snap_ignores_non_finite_boundaries() {
        let snapped = snapToLapBoundaries(140...260, boundaries: [0, .nan, 100, 200, .infinity, 300])
        #expect(snapped == 100...300)
    }

    // MARK: - Lap time boundaries

    private func lap(_ index: Int, start: Double, duration: Double) -> Lap {
        Lap(index: UInt32(index), startTimeS: start, durationS: duration, endTimeS: start + duration)
    }

    @Test func test_lap_time_boundaries_are_the_starts_plus_the_final_end() {
        let laps = [lap(0, start: 0, duration: 90), lap(1, start: 90, duration: 88), lap(2, start: 178, duration: 91)]
        #expect(lapTimeBoundaries(laps) == [0, 90, 178, 269])
    }

    @Test func test_lap_time_boundaries_skip_invalid_duration_laps() {
        let laps = [lap(0, start: 0, duration: 90), lap(1, start: 90, duration: 0), lap(2, start: 90, duration: 88)]
        #expect(lapTimeBoundaries(laps) == [0, 90, 178], "the zero-duration out-lap contributes no boundary")
    }

    @Test func test_lap_time_boundaries_of_no_valid_laps_is_empty() {
        #expect(lapTimeBoundaries([]).isEmpty)
        #expect(lapTimeBoundaries([lap(0, start: 0, duration: 0)]).isEmpty)
    }

    // MARK: - Local-time offsets

    @Test func test_local_time_offsets_align_every_lap_start_to_the_origin() {
        // Three laps starting at absolute times 12, 78, 141 → each shifts back to 0.
        let offsets = localTimeOffsets(lapStartTimes: [12, 78, 141])
        #expect(offsets == [-12, -78, -141])
    }

    @Test func test_local_time_offsets_align_to_a_chosen_reference() {
        let offsets = localTimeOffsets(lapStartTimes: [12, 78], reference: 5)
        #expect(offsets == [-7, -73], "each lap start maps onto the reference origin")
    }

    @Test func test_local_time_offset_of_a_non_finite_start_is_zero() {
        #expect(localTimeOffsets(lapStartTimes: [.nan, .infinity]) == [0, 0])
    }

    // MARK: - Trace time shift

    @Test func test_time_shift_moves_the_time_basis_but_leaves_distance_and_value() {
        let trace = ChannelTrace(name: "Speed", times: [10, 11, 12], distances: [0, 5, 10], values: [50, 60, 70])
        let shifted = trace.timeShifted(by: -10)
        #expect(shifted.xValues(mode: .time) == [0, 1, 2], "times shifted to a local origin")
        #expect(shifted.xValues(mode: .distance) == [0, 5, 10], "distance basis untouched")
        #expect(shifted.samples.map(\.value) == [50, 60, 70], "values untouched")
        #expect(shifted.name == "Speed")
    }

    @Test func test_time_shift_by_zero_is_the_identity() {
        let trace = ChannelTrace(name: "RPM", times: [1, 2], distances: [0, 3], values: [7, 8])
        #expect(trace.timeShifted(by: 0) == trace)
    }
}
