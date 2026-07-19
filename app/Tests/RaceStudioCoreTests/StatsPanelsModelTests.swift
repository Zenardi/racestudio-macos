import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `StatsPanelsModel` (issue 8.9): the analysis window's histogram +
/// scatter (G-G) panel state and assembly from the window's channel traces —
/// binning the first trace (with a configurable bin count and per-lap colouring)
/// and pairing two traces into the scatter cloud with an optional trend line.
@MainActor
@Suite struct StatsPanelsModelTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    /// A trace named `name` sampled at t = 0…count-1 with value `scale·t`.
    private func trace(_ name: String, count: Int = 11, scale: Double = 1) -> ChannelTrace {
        let times = (0..<count).map(Double.init)
        return ChannelTrace(name: name, times: times,
                            distances: Array(repeating: 0, count: count),
                            values: times.map { $0 * scale })
    }

    /// Two contiguous laps spanning 0…10 s.
    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
         Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10)]
    }

    // MARK: - Histogram panel

    @Test func test_histogram_bins_the_first_trace() {
        let panel = StatsPanelsModel().histogramPanel(traces: [trace("AccLat"), trace("AccLong")],
                                                      laps: [], selectedLaps: [])
        #expect(panel.channel == "AccLat")
        #expect(panel.overall.reduce(0) { $0 + $1.count } == 11)
        #expect(panel.perLap.isEmpty, "no selected laps → only the whole-window bars")
    }

    @Test func test_histogram_is_empty_without_traces() {
        let panel = StatsPanelsModel().histogramPanel(traces: [], laps: laps(), selectedLaps: [LapID(0)])
        #expect(panel.channel.isEmpty)
        #expect(panel.overall.isEmpty)
    }

    @Test func test_bin_count_defaults_to_twenty_and_is_settable() {
        let model = StatsPanelsModel()
        #expect(model.binCount == HistogramPanelModel.defaultBinCount)
        model.setBinCount(8)
        #expect(model.binCount == 8)
        let panel = model.histogramPanel(traces: [trace("AccLat")], laps: [], selectedLaps: [])
        #expect(panel.overall.count == 8, "AccLat spans 0…10 with spread, filling 8 bins")
    }

    @Test func test_bin_count_setter_clamps_to_a_sane_range() {
        let model = StatsPanelsModel()
        model.setBinCount(0)
        #expect(model.binCount == 1, "a non-positive count clamps to a single bin")
        model.setBinCount(100_000)
        #expect(model.binCount == 200, "an absurd count clamps to the display ceiling")
    }

    @Test func test_histogram_colours_bars_per_selected_lap() {
        let panel = StatsPanelsModel().histogramPanel(traces: [trace("AccLat")], laps: laps(),
                                                      selectedLaps: [LapID(0), LapID(1)])
        #expect(panel.perLap.map(\.id) == [LapID(0), LapID(1)])
        #expect(panel.perLap.map(\.label) == ["Lap 1", "Lap 2"])
        #expect(panel.perLap.map(\.color) == [PlotColor.palette[0], PlotColor.palette[1]])
        // `[start, end]` is sliced inclusively (as the readout grid does), so the
        // shared t = 5 boundary sample falls in both halves → 6 and 6.
        #expect(panel.perLap[0].bins.reduce(0) { $0 + $1.count } == 6)
        #expect(panel.perLap[1].bins.reduce(0) { $0 + $1.count } == 6)
    }

    @Test func test_histogram_per_lap_colour_follows_selection_order_not_session_order() {
        // Selecting lap 1 first makes it colour 0, regardless of session order.
        let panel = StatsPanelsModel().histogramPanel(traces: [trace("AccLat")], laps: laps(),
                                                      selectedLaps: [LapID(1), LapID(0)])
        #expect(panel.perLap.map(\.id) == [LapID(1), LapID(0)])
        #expect(panel.perLap[0].color == PlotColor.palette[0], "the first-selected lap gets the first colour")
    }

    @Test func test_histogram_skips_a_selected_lap_absent_from_the_session() {
        let panel = StatsPanelsModel().histogramPanel(traces: [trace("AccLat")], laps: laps(),
                                                      selectedLaps: [LapID(0), LapID(9)])
        #expect(panel.perLap.map(\.id) == [LapID(0)], "an unknown lap id contributes nothing")
    }

    @Test func test_histogram_tolerates_duplicate_lap_indices() {
        // Defensive: two laps sharing an index resolve to the first, never trapping.
        let dup = [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
                   Lap(index: 0, startTimeS: 5, durationS: 5, endTimeS: 10)]
        let panel = StatsPanelsModel().histogramPanel(traces: [trace("AccLat")], laps: dup,
                                                      selectedLaps: [LapID(0)])
        #expect(panel.perLap.count == 1, "the duplicate index collapses to one lap")
        #expect(panel.perLap[0].bins.reduce(0) { $0 + $1.count } == 6, "using the first lap's [0, 5] window")
    }

    // MARK: - Scatter (G-G) panel

    @Test func test_scatter_pairs_the_first_two_traces() throws {
        // AccLat = 1·t, AccLong = 2·t → the cloud lies on y = 2x.
        let panel = StatsPanelsModel().scatterPanel(traces: [trace("AccLat", scale: 1),
                                                             trace("AccLong", scale: 2)])
        #expect(panel.xChannel == "AccLat")
        #expect(panel.yChannel == "AccLong")
        #expect(panel.points.count == 11)
        #expect(try #require(panel.fit).slope == 2)
    }

    @Test func test_scatter_needs_two_traces() {
        let panel = StatsPanelsModel().scatterPanel(traces: [trace("AccLat")])
        #expect(panel.points.isEmpty)
        #expect(panel.yChannel.isEmpty)
    }

    @Test func test_scatter_regression_toggle_adds_and_removes_the_trend_line() {
        let model = StatsPanelsModel()
        let traces = [trace("AccLat", scale: 1), trace("AccLong", scale: 2)]
        #expect(model.regression, "the trend line is on by default")
        model.setRegression(false)
        #expect(model.scatterPanel(traces: traces).fit == nil)
        model.setRegression(true)
        #expect(model.scatterPanel(traces: traces).fit != nil)
    }

    @Test func test_scatter_axes_can_be_overridden() {
        let model = StatsPanelsModel()
        let traces = [trace("AccLat"), trace("AccLong"), trace("Speed")]
        model.setXChannel("Speed")
        model.setYChannel("AccLat")
        let panel = model.scatterPanel(traces: traces)
        #expect(panel.xChannel == "Speed")
        #expect(panel.yChannel == "AccLat")
    }

    @Test func test_scatter_axis_override_falls_back_when_its_channel_is_unavailable() {
        let model = StatsPanelsModel()
        model.setXChannel("Speed") // Speed absent from the traces below
        let panel = model.scatterPanel(traces: [trace("AccLat"), trace("AccLong")])
        #expect(panel.xChannel == "AccLat", "a stale override falls back to the first channel")
    }

    @Test func test_scatter_y_override_ignored_when_it_equals_x() {
        let model = StatsPanelsModel()
        model.setYChannel("AccLat") // same as the default x → ignored so the axes differ
        let panel = model.scatterPanel(traces: [trace("AccLat"), trace("AccLong")])
        #expect(panel.xChannel == "AccLat")
        #expect(panel.yChannel == "AccLong", "y cannot collapse onto x")
    }

    @Test func test_scatter_override_clears_on_an_empty_name() {
        let model = StatsPanelsModel()
        model.setXChannel("Speed")
        model.setXChannel("") // empty clears the override
        #expect(model.xChannelOverride == nil)
    }
}
