import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `HistogramPanelModel` (issue 8.9): the pure feed adapter that turns a
/// channel's window values (and, when laps are supplied, each lap's slice) into the
/// reused `HistogramView`'s inputs — the whole-window distribution at a configurable
/// bin count plus one per-lap distribution on a **shared** value grid, each carrying
/// a deterministic per-lap colour. Covered without SwiftUI or the FFI.
@Suite struct HistogramPanelModelTests {

    // MARK: - Overall distribution (criterion 1: a channel's value distribution)

    @Test func test_overall_bins_the_whole_window_at_the_requested_bin_count() {
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                                        binCount: 5)
        #expect(model.overall.count == 5)
        #expect(model.overall.reduce(0) { $0 + $1.count } == 11, "every value lands in exactly one bin")
        #expect(model.overall.first?.lower == 0)
        #expect(model.overall.last?.upper == 10)
    }

    @Test func test_channel_name_is_carried() {
        #expect(HistogramPanelModel(channel: "RPM", values: [1, 2, 3]).channel == "RPM")
    }

    @Test func test_bin_count_defaults_to_twenty() {
        #expect(HistogramPanelModel(channel: "Speed", values: [0, 10]).binCount
                == HistogramPanelModel.defaultBinCount)
        #expect(HistogramPanelModel.defaultBinCount == 20)
    }

    @Test func test_bin_count_is_clamped_to_at_least_one() {
        // A stepper can never send 0, but a non-positive count must degrade to a
        // usable single-bin histogram rather than a blank panel.
        let model = HistogramPanelModel(channel: "Speed", values: [0, 5, 10], binCount: 0)
        #expect(model.binCount == 1)
        #expect(model.overall.count == 1)
        #expect(model.overall.first?.count == 3)
    }

    @Test func test_empty_values_yield_no_bins() {
        let model = HistogramPanelModel(channel: "Speed", values: [])
        #expect(model.overall.isEmpty)
        #expect(model.perLap.isEmpty)
    }

    // MARK: - Per-lap distribution (criterion 3: bars coloured per lap)

    @Test func test_no_laps_leaves_per_lap_empty() {
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 3])
        #expect(model.perLap.isEmpty, "with no laps the panel shows only the whole-window bars")
        #expect(!model.overall.isEmpty)
    }

    @Test func test_one_histogram_per_lap_in_order() {
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [0, 1, 2]),
                    LapValues(id: LapID(1), label: "Lap 2", values: [8, 9, 10])]
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 8, 9, 10], laps: laps)
        #expect(model.perLap.map(\.id) == [LapID(0), LapID(1)])
        #expect(model.perLap.map(\.label) == ["Lap 1", "Lap 2"])
    }

    @Test func test_bars_are_coloured_per_lap_by_selection_order() {
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [0, 1]),
                    LapValues(id: LapID(1), label: "Lap 2", values: [2, 3]),
                    LapValues(id: LapID(2), label: "Lap 3", values: [4, 5])]
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 3, 4, 5], laps: laps)
        #expect(model.perLap.map(\.color) == [PlotColor.palette[0], PlotColor.palette[1], PlotColor.palette[2]])
    }

    @Test func test_per_lap_bins_share_one_zero_aligned_value_grid() {
        // Both laps bin onto the SAME width-1 grid derived from the whole window's
        // [0, 10] range at binCount 10, so different-range laps are comparable.
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [0, 1, 2]),
                    LapValues(id: LapID(1), label: "Lap 2", values: [8, 9, 10])]
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 8, 9, 10],
                                        laps: laps, binCount: 10)
        #expect(model.perLap[0].bins.map(\.lower) == [0, 1])
        #expect(model.perLap[0].bins.map(\.upper) == [1, 2])
        #expect(model.perLap[1].bins.map(\.lower) == [8, 9], "lap 2 aligns to the same grid, not its own min")
        #expect(model.perLap[1].bins.map(\.upper) == [9, 10])
        #expect(model.perLap[0].bins.reduce(0) { $0 + $1.count } == 3)
        #expect(model.perLap[1].bins.reduce(0) { $0 + $1.count } == 3)
    }

    @Test func test_a_lap_with_no_values_keeps_its_colour_slot_with_empty_bins() {
        // A lap that catches no samples must not shift the other laps' colours: it
        // stays in place with empty bins so selection-order colouring is stable.
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [0, 1, 2]),
                    LapValues(id: LapID(1), label: "Lap 2", values: []),
                    LapValues(id: LapID(2), label: "Lap 3", values: [8, 9, 10])]
        let model = HistogramPanelModel(channel: "Speed", values: [0, 1, 2, 8, 9, 10], laps: laps)
        #expect(model.perLap.count == 3)
        #expect(model.perLap[1].bins.isEmpty)
        #expect(model.perLap[2].color == PlotColor.palette[2], "the empty lap did not steal lap 3's colour")
    }

    @Test func test_degenerate_range_falls_back_to_independent_per_lap_binning() {
        // When the whole window has no spread (every value equal), no shared width
        // exists — each lap falls back to its own equal-value single bin.
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [7, 7]),
                    LapValues(id: LapID(1), label: "Lap 2", values: [7])]
        let model = HistogramPanelModel(channel: "Speed", values: [7, 7, 7], laps: laps, binCount: 10)
        #expect(model.perLap[0].bins.count == 1)
        #expect(model.perLap[0].bins.first?.count == 2)
        #expect(model.perLap[1].bins.count == 1)
        #expect(model.perLap[1].bins.first?.count == 1)
    }

    @Test func test_per_lap_counts_ignore_non_finite_lap_samples() {
        let laps = [LapValues(id: LapID(0), label: "Lap 1", values: [0, .nan, 5, .infinity, 10])]
        let model = HistogramPanelModel(channel: "Speed", values: [0, 5, 10], laps: laps, binCount: 5)
        #expect(model.perLap[0].bins.reduce(0) { $0 + $1.count } == 3, "only finite lap samples are counted")
    }
}
