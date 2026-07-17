import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LapOverlayViewModel` (issue 4.2) — overlaid traces, colors, and
/// the delta-t strip/readout, consuming the 3.2 delta golden.
@Suite struct LapOverlayViewModelTests {

    // MARK: - Golden decodable (snake_case → camelCase via FixtureLoader)

    private struct DeltaGolden: Decodable {
        let referenceIndex: Int
        let comparisonIndex: Int
        let points: [DeltaPointGolden]
    }
    private struct DeltaPointGolden: Decodable { let distance: Double; let dt: Double }

    // MARK: - Fixtures

    private func lap(_ index: Int, distances: [Double], speed: [Double]) -> OverlayLap {
        OverlayLap(
            id: LapID(index),
            label: "Lap \(index + 1)",
            times: distances.indices.map(Double.init),
            distances: distances,
            channels: ["Speed": speed])
    }

    // MARK: - Traces

    @Test func test_traces_are_distance_aligned_per_selected_lap() {
        let a = lap(0, distances: [0, 50, 100], speed: [10, 20, 30])
        let b = lap(1, distances: [0, 60], speed: [15, 25])
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0), LapID(1)], reference: LapID(0)),
            laps: [a, b],
            deltas: [:])

        let traces = model.traces(for: "Speed")
        #expect(traces.count == 2)
        #expect(traces[0].name == "Lap 1")
        #expect(traces[0].xValues(mode: .distance) == [0, 50, 100])
        #expect(traces[1].xValues(mode: .distance) == [0, 60])
    }

    @Test func test_traces_skip_a_channel_no_lap_carries() {
        let a = lap(0, distances: [0, 50], speed: [10, 20])
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0)], reference: LapID(0)),
            laps: [a],
            deltas: [:])
        #expect(model.traces(for: "Nonexistent").isEmpty)
    }

    @Test func test_empty_selection_yields_no_traces() {
        let model = LapOverlayViewModel(selection: LapSelectionModel(), laps: [], deltas: [:])
        #expect(model.traces(for: "Speed").isEmpty)
        #expect(model.deltaStrip(reference: LapID(0), target: LapID(1)).isEmpty)
    }

    // MARK: - Colors

    @Test func test_overlay_assigns_distinct_stable_colors() {
        let ids = [LapID(0), LapID(1), LapID(2)]
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: ids, reference: ids[0]),
            laps: [],
            deltas: [:])

        let colors = ids.map(model.colorForLap)
        #expect(Set(colors).count == 3, "distinct")
        // Deterministic by selection order…
        #expect(colors[0] == PlotColor.palette[0])
        #expect(colors[1] == PlotColor.palette[1])
        #expect(colors[2] == PlotColor.palette[2])
        // …stable across calls.
        #expect(model.colorForLap(ids[0]) == colors[0])
        // A lap outside the selection gets the neutral color.
        #expect(model.colorForLap(LapID(99)) == PlotColor.unselected)
    }

    @Test func test_palette_wraps_when_more_laps_than_colors() {
        let count = PlotColor.palette.count
        let ids = (0...count).map { LapID($0) }
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: ids, reference: ids[0]),
            laps: [],
            deltas: [:])
        // The (count+1)-th lap wraps back to the first palette color.
        #expect(model.colorForLap(ids[count]) == PlotColor.palette[0])
    }

    // MARK: - Delta strip

    @Test func test_delta_strip_reference_vs_itself_is_zero() {
        let reference = lap(0, distances: [0, 50, 120], speed: [10, 20, 30])
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0)], reference: LapID(0)),
            laps: [reference],
            deltas: [:])

        let strip = model.deltaStrip(reference: LapID(0), target: LapID(0))
        #expect(strip.map(\.distance) == [0, 50, 120])
        #expect(strip.allSatisfy { $0.dt == 0 }, "reference vs itself is all zeros")
    }

    @Test func test_delta_strip_matches_3_2_golden() throws {
        let golden: DeltaGolden = try FixtureLoader.golden("aim_official_test", aspect: "delta_t")
        let reference = LapID(golden.referenceIndex)
        let target = LapID(golden.comparisonIndex)
        let series = golden.points.map { DeltaSample(distance: $0.distance, dt: $0.dt) }

        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [reference, target], reference: reference),
            laps: [],
            deltas: [DeltaPair(reference: reference, target: target): series])

        let strip = model.deltaStrip(reference: reference, target: target)
        try #require(strip.count == golden.points.count)
        for (got, want) in zip(strip, golden.points) {
            #expect(abs(got.distance - want.distance) < 1e-6)
            #expect(abs(got.dt - want.dt) < 1e-6)
        }
    }

    // MARK: - Cursor readout

    @Test func test_delta_at_cursor_reports_leading_lap() throws {
        let golden: DeltaGolden = try FixtureLoader.golden("aim_official_test", aspect: "delta_t")
        let reference = LapID(golden.referenceIndex)
        let target = LapID(golden.comparisonIndex)
        let series = golden.points.map { DeltaSample(distance: $0.distance, dt: $0.dt) }
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [reference, target], reference: reference),
            laps: [],
            deltas: [DeltaPair(reference: reference, target: target): series])

        // Mid-lap the comparison lap (8) is ahead of the reference (1): dt < 0,
        // so the target leads.
        let midDistance = golden.points[golden.points.count / 2].distance
        let readout = try #require(
            model.deltaAtCursor(reference: reference, target: target, distance: midDistance))
        #expect(readout.dt < 0)
        #expect(readout.leader == target)

        // No strip for an unknown pair → no readout.
        #expect(model.deltaAtCursor(reference: reference, target: LapID(999), distance: 0) == nil)
    }

    /// Synthetic strip: reference ahead early (dt > 0), tied at the crossover.
    private func synthetic() -> LapOverlayViewModel {
        let series = [DeltaSample(distance: 0, dt: 0),
                      DeltaSample(distance: 100, dt: 2),
                      DeltaSample(distance: 200, dt: 0)]
        return LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0), LapID(1)], reference: LapID(0)),
            laps: [],
            deltas: [DeltaPair(reference: LapID(0), target: LapID(1)): series])
    }

    @Test func test_delta_at_cursor_reference_leads_when_dt_positive() {
        let readout = synthetic().deltaAtCursor(reference: LapID(0), target: LapID(1), distance: 100)
        #expect(readout?.leader == LapID(0), "dt > 0 → reference leads")
    }

    @Test func test_delta_at_cursor_ties_when_dt_zero() {
        let readout = synthetic().deltaAtCursor(reference: LapID(0), target: LapID(1), distance: 0)
        #expect(readout?.leader == nil, "dt == 0 → no leader")
    }

    @Test func test_delta_at_cursor_clamps_past_the_last_sample() {
        let readout = synthetic().deltaAtCursor(reference: LapID(0), target: LapID(1), distance: 10_000)
        #expect(readout?.dt == 0, "clamped to the last sample")
    }

    @Test func test_delta_at_cursor_rejects_nonfinite_distance() {
        #expect(synthetic().deltaAtCursor(reference: LapID(0), target: LapID(1), distance: .nan) == nil)
        #expect(synthetic().deltaAtCursor(reference: LapID(0), target: LapID(1), distance: .infinity) == nil)
    }

    @Test func test_delta_strip_reversed_pair_is_negated() {
        // Only (A, B) is supplied; querying (B, A) negates it (antisymmetry),
        // so a reference swap in the UI never blanks the strip.
        let series = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 100, dt: -1.5)]
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0), LapID(1)], reference: LapID(1)),
            laps: [],
            deltas: [DeltaPair(reference: LapID(0), target: LapID(1)): series])

        let reversed = model.deltaStrip(reference: LapID(1), target: LapID(0))
        #expect(reversed.map(\.distance) == [0, 100])
        #expect(reversed.map(\.dt) == [0, 1.5], "reversed orientation negates dt")
    }

    @Test func test_duplicate_lap_ids_keep_first() {
        let first = lap(0, distances: [0, 10], speed: [1, 2])
        let dup = OverlayLap(id: LapID(0), label: "Dup", times: [0], distances: [0], channels: ["Speed": [9]])
        let model = LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0)], reference: LapID(0)),
            laps: [first, dup],
            deltas: [:])

        let traces = model.traces(for: "Speed")
        #expect(traces.count == 1)
        #expect(traces[0].name == "Lap 1", "the first lap for a duplicate id wins")
    }
}
