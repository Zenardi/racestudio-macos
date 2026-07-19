import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisWindowModel` (issue 8.3) — the `@MainActor` Core state
/// behind the analysis window shell: the layout rail's panel set + active
/// layout, the channel/lap selection preserved across layout switches, the
/// Time/Distance traces fed by the 8.1 `AnalysisSession`, and the measures-bar
/// value-at-cursor. The SwiftUI `AnalysisWindowView` stays thin, so all of this
/// is covered FFI-free through a `FakeSessionDataSource`.
@MainActor
@Suite struct AnalysisWindowModelTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func channel(_ name: String, unit: String = "", decimals: UInt8 = 0, count: UInt32 = 10) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: 10, decimals: decimals, sampleCount: count)
    }

    /// Two contiguous laps spanning 0…10 s, so the cursor's bounds are [0, 10].
    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
         Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10)]
    }

    private func session(_ channels: [Channel], laps: [Lap]? = nil) -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "SFJ", track: "Fuji", driver: "CMD",
                                      session: "", series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: channels, laps: laps ?? self.laps())
    }

    /// Sample bank: sample `i` is `(time: i, value: scale·i)`, so a value read at
    /// the cursor is trivially predictable.
    private func bank(_ count: Int, scale: Double) -> [DataSample] {
        (0..<count).map { DataSample(time: Double($0), value: Double($0) * scale) }
    }

    /// A model over a `Speed` (×2, km/h, 1 dp) + `RPM` (×10, rpm, 0 dp) session.
    private func makeModel(analysisPresent: Bool = true) -> AnalysisWindowModel {
        let sess = session([channel("Speed", unit: "km/h", decimals: 1),
                            channel("RPM", unit: "rpm", decimals: 0)])
        let analysis: AnalysisSession? = analysisPresent
            ? AnalysisSession(session: sess,
                              dataSource: FakeSessionDataSource(banks: [bank(10, scale: 2), bank(10, scale: 10)]))
            : nil
        return AnalysisWindowModel(session: sess, analysis: analysis)
    }

    // MARK: - Layout rail (panel set + active layout)

    @Test func test_layouts_expose_the_rail_panel_set_in_order() {
        #expect(makeModel().layouts == [.timeDistance, .channelTable, .trackMap, .lapOverlay, .summary])
    }

    @Test func test_initial_active_layout_is_time_distance_not_the_summary() {
        #expect(makeModel().activeLayout == .timeDistance)
    }

    @Test func test_selecting_a_layout_makes_it_active() {
        let model = makeModel()
        model.select(layout: .summary)
        #expect(model.activeLayout == .summary)
    }

    @Test func test_selecting_swaps_the_active_layout_both_ways() {
        let model = makeModel()
        model.select(layout: .summary)
        model.select(layout: .timeDistance)
        #expect(model.activeLayout == .timeDistance)
    }

    @Test func test_layout_titles_label_the_rail() {
        #expect(WindowLayout.timeDistance.title == "Time / Distance")
        #expect(WindowLayout.channelTable.title == "Channels")
        #expect(WindowLayout.trackMap.title == "Track Map")
        #expect(WindowLayout.lapOverlay.title == "Lap Overlay")
        #expect(WindowLayout.summary.title == "Summary")
    }

    @Test func test_layout_system_image_names_are_stable() {
        #expect(WindowLayout.timeDistance.systemImageName == "chart.xyaxis.line")
        #expect(WindowLayout.channelTable.systemImageName == "tablecells")
        #expect(WindowLayout.trackMap.systemImageName == "map")
        #expect(WindowLayout.lapOverlay.systemImageName == "point.3.connected.trianglepath.dotted")
        #expect(WindowLayout.summary.systemImageName == "list.bullet.rectangle")
    }

    // MARK: - Default selection

    @Test func test_first_channel_is_selected_by_default_so_the_plot_is_live() {
        #expect(makeModel().selection.channels == [ChannelID("Speed")])
    }

    @Test func test_toggle_channel_adds_then_removes_preserving_order() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        #expect(model.selection.channels == [ChannelID("Speed"), ChannelID("RPM")])
        model.toggleChannel(ChannelID("Speed"))
        #expect(model.selection.channels == [ChannelID("RPM")])
    }

    @Test func test_toggle_lap_adds_then_removes() {
        let model = makeModel()
        model.toggleLap(LapID(0))
        #expect(model.selection.laps.selected == [LapID(0)])
        model.toggleLap(LapID(0))
        #expect(model.selection.laps.selected.isEmpty)
    }

    // MARK: - Time/Distance wiring (traces fed by AnalysisSession)

    @Test func test_traces_reflect_the_selected_channels() {
        let model = makeModel()
        #expect(model.traces.map(\.name) == ["Speed"]) // only Speed selected by default
        #expect(model.traces.first?.samples.count == 10)
    }

    @Test func test_toggling_a_channel_updates_the_traces() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        #expect(model.traces.map(\.name) == ["Speed", "RPM"])
    }

    @Test func test_traces_are_empty_without_an_analysis_pump() {
        #expect(makeModel(analysisPresent: false).traces.isEmpty)
    }

    // MARK: - Measures bar (value-at-cursor)

    @Test func test_measures_report_value_at_cursor_for_selected_channels() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        model.linkedCursor.moveTime(3)

        let measures = model.measures
        #expect(measures.map(\.channel) == [ChannelID("Speed"), ChannelID("RPM")])
        // Speed = 2·t, RPM = 10·t, read at t = 3.
        #expect(measures[0].readout.value == 6)
        #expect(measures[1].readout.value == 30)
        #expect(measures[0].formatted == "6.0 km/h", "unit + precision from the channel")
        #expect(measures[1].formatted == "30 rpm")
    }

    @Test func test_measures_update_when_the_cursor_moves() {
        let model = makeModel()
        model.linkedCursor.moveTime(2)
        #expect(model.measures.first?.readout.value == 4)
        model.linkedCursor.moveTime(4)
        #expect(model.measures.first?.readout.value == 8)
    }

    @Test func test_measures_are_empty_when_no_channel_is_selected() {
        let model = makeModel()
        model.toggleChannel(ChannelID("Speed")) // deselect the default
        #expect(model.selection.channels.isEmpty)
        #expect(model.measures.isEmpty)
    }

    @Test func test_measures_are_empty_without_an_analysis_pump() {
        #expect(makeModel(analysisPresent: false).measures.isEmpty)
    }

    // MARK: - Selection preservation across layout switches (the key behaviour)

    @Test func test_switching_layout_preserves_channel_selection() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        let before = model.selection.channels

        model.select(layout: .summary)

        #expect(model.selection.channels == before)
        #expect(model.traces.map(\.name) == ["Speed", "RPM"], "the selection still drives the traces")
    }

    @Test func test_switching_layout_preserves_lap_selection() {
        let model = makeModel()
        model.toggleLap(LapID(1))

        model.select(layout: .summary)

        #expect(model.selection.laps.selected == [LapID(1)])
    }

    @Test func test_switching_layout_preserves_the_cursor_position() {
        let model = makeModel()
        model.linkedCursor.moveTime(7)

        model.select(layout: .summary)
        model.select(layout: .timeDistance)

        #expect(model.linkedCursor.timePosition == 7)
    }

    // MARK: - Cursor basis (session bounds)

    @Test func test_cursor_bounds_come_from_the_session_laps() {
        #expect(makeModel().linkedCursor.timeBounds == 0...10)
    }

    @Test func test_cursor_move_is_clamped_to_the_session_bounds() {
        let model = makeModel()
        model.linkedCursor.moveTime(999)
        #expect(model.linkedCursor.timePosition == 10)
    }

    @Test func test_cursor_has_no_bounds_for_a_lapless_session_without_a_pump() {
        let sess = session([channel("Speed")], laps: [])
        let model = AnalysisWindowModel(session: sess, analysis: nil)
        #expect(model.linkedCursor.timeBounds == nil)
    }

    @Test func test_cursor_bounds_fall_back_to_the_channel_extent_without_laps() {
        let sess = session([channel("Speed", count: 10)], laps: [])
        let source = FakeSessionDataSource(banks: [bank(10, scale: 2)])
        let model = AnalysisWindowModel(session: sess, analysis: AnalysisSession(session: sess, dataSource: source))
        // No laps → the cursor is bounded by the selected channel's sample times (0…9).
        #expect(model.linkedCursor.timeBounds == 0...9)
        #expect(model.linkedCursor.scrubRange == 0...9)
    }

    @Test func test_empty_session_has_no_selection_traces_or_measures() {
        let model = AnalysisWindowModel(session: session([], laps: []), analysis: nil)
        #expect(model.selection.channels.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.traces.isEmpty)
        #expect(model.measures.isEmpty)
        #expect(model.linkedCursor.timeBounds == nil)
    }

    // MARK: - Edge cases (defensive branches)

    @Test func test_selecting_a_layout_absent_from_the_rail_is_a_no_op() {
        let sess = session([channel("Speed")])
        let model = AnalysisWindowModel(session: sess, analysis: nil, layouts: [.timeDistance])
        model.select(layout: .summary) // not offered by this rail
        #expect(model.activeLayout == .timeDistance)
    }

    @Test func test_active_layout_falls_back_when_the_rail_is_empty() {
        let sess = session([channel("Speed")])
        let model = AnalysisWindowModel(session: sess, analysis: nil, layouts: [])
        #expect(model.layouts.isEmpty)
        #expect(model.activeLayout == .timeDistance, "a safe default when no layout is offered")
    }

    @Test func test_duplicate_channel_names_index_the_first_occurrence() {
        let sess = session([channel("Dup", count: 4), channel("Dup", count: 4)])
        let source = FakeSessionDataSource(banks: [bank(4, scale: 2), bank(4, scale: 99)])
        let model = AnalysisWindowModel(session: sess, analysis: AnalysisSession(session: sess, dataSource: source))
        // The default selection resolves "Dup" to the first channel (bank 0, ×2),
        // so its last sample is 2·3 = 6 — not the second channel's ×99 bank.
        #expect(model.traces.count == 1)
        #expect(model.traces.first?.samples.last?.value == 6)
    }

    // MARK: - Identity / convenience API (drives the SwiftUI bindings)

    @Test func test_window_layout_id_is_the_raw_value() {
        #expect(WindowLayout.timeDistance.id == "timeDistance")
        #expect(WindowLayout.channelTable.id == "channelTable")
        #expect(WindowLayout.trackMap.id == "trackMap")
        #expect(WindowLayout.lapOverlay.id == "lapOverlay")
        #expect(WindowLayout.summary.id == "summary")
    }

    @Test func test_selection_is_empty_reflects_the_channel_list() {
        var selection = AnalysisSelection()
        #expect(selection.isEmpty)
        selection.toggleChannel(ChannelID("Speed"))
        #expect(!selection.isEmpty)
    }

    @Test func test_channel_measure_id_is_the_channel_name() {
        let measure = ChannelMeasure(channel: ChannelID("RPM"),
                                     readout: Readout(value: 1, extrapolated: false), formatted: "1 rpm")
        #expect(measure.id == "RPM")
    }

    // MARK: - Convenience init from the loaded view-model

    @Test func test_init_from_view_model_carries_the_session_and_pump() {
        let sess = session([channel("Speed", count: 4)])
        let source = FakeSessionDataSource(banks: [bank(4, scale: 2)])
        let viewModel = SessionViewModel(session: sess, analysis: AnalysisSession(session: sess, dataSource: source))

        let model = AnalysisWindowModel(viewModel: viewModel)

        #expect(model.session == sess)
        #expect(model.traces.map(\.name) == ["Speed"])
    }

    // MARK: - Side panel (issue 8.4: search / sort / colour, driven by the shared model)

    @Test func test_side_panel_defaults_to_configuration_order_and_no_query() {
        let model = makeModel()
        #expect(model.channelQuery.isEmpty)
        #expect(model.channelSort == .configuration)
        #expect(model.sidePanel.channelRows.map(\.name) == ["Speed", "RPM"])
    }

    @Test func test_side_panel_reflects_the_default_channel_selection() {
        // The window opens with the first channel selected, so its side-panel row
        // is on and carries the first palette colour.
        let speed = makeModel().sidePanel.channelRows.first { $0.name == "Speed" }
        #expect(speed?.isSelected == true)
        #expect(speed?.color == PlotColor.palette[0])
    }

    @Test func test_setting_the_query_filters_the_side_panel_channels() {
        let model = makeModel()
        model.setChannelQuery("rpm")
        #expect(model.channelQuery == "rpm")
        #expect(model.sidePanel.channelRows.map(\.name) == ["RPM"])
    }

    @Test func test_setting_the_sort_reorders_the_side_panel_channels() {
        let model = makeModel()
        model.setChannelSort(.alphabetical)
        #expect(model.channelSort == .alphabetical)
        #expect(model.sidePanel.channelRows.map(\.name) == ["RPM", "Speed"])
    }

    @Test func test_toggling_a_channel_updates_both_the_side_panel_and_the_plot() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        // The plot sees the new trace…
        #expect(model.traces.map(\.name) == ["Speed", "RPM"])
        // …and the side panel shows RPM on, with the second palette colour.
        let rpm = model.sidePanel.channelRows.first { $0.name == "RPM" }
        #expect(rpm?.isSelected == true)
        #expect(rpm?.color == PlotColor.palette[1])
    }

    @Test func test_toggling_a_lap_updates_the_side_panel_visibility() {
        let model = makeModel()
        model.toggleLap(LapID(1))
        let lap = model.sidePanel.lapRows.first { $0.lap == LapID(1) }
        #expect(lap?.isVisible == true)
        #expect(lap?.color == PlotColor.palette[0])
    }

}
