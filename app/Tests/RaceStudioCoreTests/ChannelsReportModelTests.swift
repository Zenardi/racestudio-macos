import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelsReportModel` (issue 8.10): the analysis window's Channels
/// Report state + assembly from the window's channel traces — the per-lap (or
/// per-segment) min/max/avg/median table, the chosen-statistic-vs-lap graph
/// hot-tracked to the selected row, and the magic-wand presets.
@MainActor
@Suite struct ChannelsReportModelTests {

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

    /// One lap spanning 0…10 s (for per-segment splitting).
    private func wholeLap() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 10, endTimeS: 10)]
    }

    // MARK: - Table assembly (criterion 1: min/max/avg/median per channel per lap)

    @Test func test_table_has_a_row_per_channel_and_a_column_per_shown_lap() {
        let table = ChannelsReportModel().table(traces: [trace("Speed"), trace("RPM")], laps: laps())
        #expect(table.rows.map(\.channel) == [ChannelID("Speed"), ChannelID("RPM")])
        #expect(table.columns.map(\.label) == ["Lap 1", "Lap 2"])
    }

    @Test func test_each_cell_carries_min_max_average_and_median_for_its_lap() throws {
        // Lap 1 spans [0, 5] inclusively → values {0…5}: min 0, max 5, avg 2.5, median 2.5.
        let table = ChannelsReportModel().table(traces: [trace("Speed")], laps: laps())
        let stats = try #require(table.rows[0].cells[0].statistics)
        #expect(stats.minimum == 0)
        #expect(stats.maximum == 5)
        #expect(stats.average == 2.5)
        #expect(stats.median == 2.5)
    }

    @Test func test_table_is_empty_without_traces() {
        let table = ChannelsReportModel().table(traces: [], laps: laps())
        #expect(table.rows.isEmpty)
        #expect(table.isEmpty)
    }

    @Test func test_table_is_empty_without_laps() {
        let table = ChannelsReportModel().table(traces: [trace("Speed")], laps: [])
        #expect(table.columns.isEmpty)
        #expect(table.isEmpty)
    }

    @Test func test_a_lap_with_no_samples_in_range_yields_a_no_data_cell() {
        // A lap far past the channel's samples has no values → a nil-statistics cell.
        let far = [Lap(index: 0, startTimeS: 100, durationS: 5, endTimeS: 105)]
        let table = ChannelsReportModel().table(traces: [trace("Speed")], laps: far)
        #expect(table.rows[0].cells[0].statistics == nil)
    }

    @Test func test_table_deduplicates_duplicate_lap_indices() {
        // Defensive: two laps sharing an index resolve to the first, never trapping.
        let dup = [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
                   Lap(index: 0, startTimeS: 5, durationS: 5, endTimeS: 10)]
        let table = ChannelsReportModel().table(traces: [trace("Speed")], laps: dup)
        #expect(table.columns.count == 1, "the duplicate index collapses to one column")
        #expect(table.rows[0].cells[0].statistics?.maximum == 5, "using the first lap's [0, 5] window")
    }

    @Test func test_table_deduplicates_duplicate_channel_names() {
        let table = ChannelsReportModel().table(traces: [trace("Speed"), trace("Speed", scale: 2)],
                                                laps: laps())
        #expect(table.rows.count == 1, "the duplicate channel name collapses to the first trace")
    }

    // MARK: - Statistic + graph (criterion 2: chosen statistic vs lap, hot-tracked)

    @Test func test_statistic_defaults_to_average_and_is_settable() {
        let model = ChannelsReportModel()
        #expect(model.statistic == .average)
        model.setStatistic(.maximum)
        #expect(model.statistic == .maximum)
    }

    @Test func test_graph_plots_the_chosen_statistic_vs_lap_number_for_the_selected_row() {
        let model = ChannelsReportModel()
        model.setStatistic(.maximum)
        let table = model.table(traces: [trace("Speed", scale: 1), trace("RPM", scale: 10)], laps: laps())
        model.selectRow(ChannelID("RPM"))
        let graph = model.graph(from: table)
        #expect(graph.channel == ChannelID("RPM"))
        #expect(graph.statistic == .maximum)
        #expect(graph.points.map(\.x) == [1, 2], "the x-axis is the lap number")
        // RPM = 10·t → max over Lap 1 [0, 5] = 50, over Lap 2 [5, 10] = 100.
        #expect(graph.points.map(\.value) == [50, 100])
    }

    @Test func test_graph_defaults_to_the_first_row_when_no_row_is_selected() {
        let model = ChannelsReportModel()
        let table = model.table(traces: [trace("Speed"), trace("RPM")], laps: laps())
        #expect(model.graph(from: table).channel == ChannelID("Speed"))
    }

    @Test func test_graph_falls_back_to_the_first_row_for_a_stale_selection() {
        let model = ChannelsReportModel()
        model.selectRow(ChannelID("Ghost"))
        let table = model.table(traces: [trace("Speed")], laps: laps())
        #expect(model.graph(from: table).channel == ChannelID("Speed"),
                "a row no longer in the table falls back to the first")
    }

    @Test func test_graph_highlights_the_selected_column_point() {
        // Hot-track: selecting a table column highlights its point on the graph.
        let model = ChannelsReportModel()
        let table = model.table(traces: [trace("Speed")], laps: laps())
        let column = table.columns[1].id
        model.highlightColumn(column)
        let graph = model.graph(from: table)
        #expect(graph.highlighted?.column == column)
        #expect(graph.highlighted?.x == 2)
    }

    @Test func test_highlight_clears_on_an_empty_column_id() {
        let model = ChannelsReportModel()
        model.highlightColumn("lap-0")
        model.highlightColumn("")
        #expect(model.highlightedColumn == nil)
    }

    @Test func test_graph_is_empty_without_rows() {
        let model = ChannelsReportModel()
        let graph = model.graph(from: model.table(traces: [], laps: laps()))
        #expect(graph.channel == nil)
        #expect(graph.points.isEmpty)
        #expect(graph.highlighted == nil)
    }

    // MARK: - Presets (criterion 3)

    @Test func test_apply_preset_sets_the_statistic_and_records_the_active_preset() {
        let model = ChannelsReportModel()
        model.applyPreset(.vehicleHealth)
        #expect(model.statistic == .maximum, "the preset populates the statistic")
        #expect(model.activePreset == .vehicleHealth)
    }

    // MARK: - Per-segment mode (criterion 4)

    @Test func test_default_mode_is_per_lap() {
        #expect(ChannelsReportModel().mode == .perLap)
    }

    @Test func test_segment_count_defaults_to_three_and_clamps_to_a_sane_range() {
        let model = ChannelsReportModel()
        #expect(model.segmentCount == 3)
        model.setSegmentCount(0)
        #expect(model.segmentCount == 2, "a degenerate count clamps up to the minimum")
        model.setSegmentCount(10_000)
        #expect(model.segmentCount == 20, "an absurd count clamps to the ceiling")
    }

    @Test func test_per_segment_mode_splits_each_lap_into_segments() {
        let model = ChannelsReportModel()
        model.setMode(.perSegment)
        model.setSegmentCount(2)
        let table = model.table(traces: [trace("Speed")], laps: wholeLap())
        #expect(table.columns.count == 2, "one lap × two segments")
        #expect(table.columns.map(\.label) == ["Lap 1 · S1", "Lap 1 · S2"])
    }

    @Test func test_per_segment_mode_computes_statistics_per_segment() throws {
        let model = ChannelsReportModel()
        model.setMode(.perSegment)
        model.setSegmentCount(2)
        // Lap [0, 10] split at 5 → segment 1 [0, 5] max 5, segment 2 [5, 10] max 10.
        let cells = model.table(traces: [trace("Speed")], laps: wholeLap()).rows[0].cells
        #expect(try #require(cells[0].statistics).maximum == 5)
        #expect(try #require(cells[1].statistics).maximum == 10)
    }

    @Test func test_report_mode_titles_and_ids_label_the_control() {
        #expect(ReportMode.perLap.title == "Per Lap")
        #expect(ReportMode.perSegment.title == "Per Segment")
        #expect(ReportMode.perLap.id == "perLap")
        #expect(ReportMode.perSegment.id == "perSegment")
    }

    @Test func test_per_segment_mode_falls_back_to_a_whole_lap_segment_for_a_zero_width_lap() {
        let model = ChannelsReportModel()
        model.setMode(.perSegment)
        let zero = [Lap(index: 0, startTimeS: 5, durationS: 0, endTimeS: 5)]
        let columns = model.intervals(for: zero)
        #expect(columns.count == 1, "a zero-width lap yields a single whole-lap segment")
        #expect(columns[0].label == "Lap 1 · S1")
        #expect(columns[0].start == 5 && columns[0].end == 5)
    }

    @Test func test_identifiable_ids_drive_swiftui_diffing() {
        let model = ChannelsReportModel()
        let table = model.table(traces: [trace("Speed")], laps: laps())
        #expect(table.columns[0].id == "lap-0")
        #expect(table.rows[0].id == "Speed")
        #expect(table.rows[0].cells[0].id == "Speed\u{1F}lap-0")
        let point = model.graph(from: table).points.first
        #expect(point?.id == point?.column)
    }
}
