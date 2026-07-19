import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisWindowModel`'s channel table / measures panel (issue 8.5):
/// the channels × selected-laps value-at-cursor grid, per-lap extrapolation, the
/// reference-lap deltas, pinned channels, and the per-channel formatters that feed
/// the reused `ChannelTableView`. Covered FFI-free through a `FakeSessionDataSource`.
@MainActor
@Suite struct AnalysisWindowMeasuresTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func channel(_ name: String, unit: String = "", decimals: UInt8 = 0, count: UInt32 = 10) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: 10, decimals: decimals, sampleCount: count)
    }

    /// Two contiguous laps spanning 0…10 s.
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

    /// Sample bank: sample `i` is `(time: i, value: scale·i)`.
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

    /// The measures panel over both channels and both laps selected.
    private func tableModel() -> AnalysisWindowModel {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM")) // Speed + RPM
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(1))             // both laps → reference = lap 0
        return model
    }

    // MARK: - Readout grid (channels × selected laps)

    @Test func test_readout_table_is_channels_by_selected_laps() {
        let table = tableModel().readoutTable
        #expect(table.rows == [ChannelID("Speed"), ChannelID("RPM")], "a row per selected channel, in order")
        #expect(table.columns == [LapID(0), LapID(1)], "a column per selected lap, in order")
    }

    @Test func test_readout_table_is_empty_without_selected_laps() {
        // The default window selects a channel but no lap → an empty grid.
        #expect(makeModel().readoutTable.cells(atX: 0).isEmpty)
    }

    @Test func test_readout_table_updates_the_value_at_cursor_by_interpolation() {
        // Speed = 2·t. At t = 3 (inside lap 0's [0,5] window) the lap-0 cell reads 6.
        let cells = tableModel().readoutTable.cells(atX: 3)
        #expect(cells[0][0].channel == ChannelID("Speed") && cells[0][0].lap == LapID(0))
        #expect(cells[0][0].readout?.value == 6)
        #expect(cells[0][0].readout?.extrapolated == false, "inside the lap → a real reading")
    }

    @Test func test_cursor_outside_a_laps_range_is_extrapolated() {
        // At t = 3 the cursor is before lap 1's [5,10] window, so lap 1 clamps to
        // its first sample (t=5 → 2·5 = 10) and is flagged extrapolated (greyed).
        let cells = tableModel().readoutTable.cells(atX: 3)
        let lap1 = cells[0][1]
        #expect(lap1.lap == LapID(1))
        #expect(lap1.readout?.value == 10)
        #expect(lap1.readout?.extrapolated == true)
    }

    @Test func test_the_live_lap_follows_the_cursor() {
        // Moving the cursor to t = 8 flips which lap reads live: lap 1 is now
        // inside its window (2·8 = 16) and lap 0 clamps to its end (2·5 = 10).
        let cells = tableModel().readoutTable.cells(atX: 8)
        #expect(cells[0][0].readout?.extrapolated == true, "lap 0 is now past its end")
        #expect(cells[0][1].readout?.value == 16)
        #expect(cells[0][1].readout?.extrapolated == false)
    }

    @Test func test_readout_table_is_empty_without_an_analysis_pump() {
        let model = makeModel(analysisPresent: false)
        model.toggleLap(LapID(0))
        #expect(model.readoutTable.cells(atX: 0).isEmpty, "no data source → no rows")
    }

    @Test func test_readout_table_tracks_channel_and_lap_selection_changes() {
        let model = makeModel() // Speed selected, no laps
        model.toggleLap(LapID(0))
        #expect(model.readoutTable.rows == [ChannelID("Speed")])
        #expect(model.readoutTable.columns == [LapID(0)])

        model.toggleChannel(ChannelID("RPM"))
        #expect(model.readoutTable.rows == [ChannelID("Speed"), ChannelID("RPM")])

        model.toggleLap(LapID(1))
        #expect(model.readoutTable.columns == [LapID(0), LapID(1)])
    }

    @Test func test_a_lap_outside_the_channel_samples_is_a_no_data_cell() {
        // Speed spans t=0…9; a lap out at [50,55] has no samples, so its cell has
        // no data rather than a bogus reading.
        let sess = session([channel("Speed", count: 10)],
                           laps: [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
                                  Lap(index: 1, startTimeS: 50, durationS: 5, endTimeS: 55)])
        let source = FakeSessionDataSource(banks: [bank(10, scale: 2)])
        let model = AnalysisWindowModel(session: sess, analysis: AnalysisSession(session: sess, dataSource: source))
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(1))
        let cells = model.readoutTable.cells(atX: 3)
        #expect(cells[0][0].hasData == true, "lap 0 overlaps the samples")
        #expect(cells[0][1].hasData == false, "lap 1 is outside the samples")
    }

    @Test func test_a_selected_lap_absent_from_the_session_has_no_series() {
        // Defensive: a lap id with no matching session lap still forms a column,
        // but contributes no series — its cells read as no-data rather than trapping.
        let model = makeModel()
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(999)) // not a lap in this session
        #expect(model.readoutTable.columns == [LapID(0), LapID(999)])
        let cells = model.readoutTable.cells(atX: 3)
        #expect(cells[0][0].hasData == true, "the real lap has data")
        #expect(cells[0][1].hasData == false, "the phantom lap has none")
    }

    // MARK: - Reference deltas

    @Test func test_reference_is_the_first_selected_lap_by_default() {
        #expect(tableModel().selection.laps.reference == LapID(0))
    }

    @Test func test_reference_deltas_read_against_the_reference_lap() {
        let model = tableModel() // reference = lap 0
        let rows = model.readoutTable.deltaCells(atX: 3, reference: model.selection.laps.reference)
        // Speed lap 0 is the baseline → no delta; lap 1 clamps to 10 vs 6 → +4.
        #expect(rows[0][0].delta == nil)
        #expect(rows[0][1].delta == 4)
    }

    @Test func test_set_reference_lap_repoints_the_deltas() {
        let model = tableModel()
        model.setReferenceLap(LapID(1))
        #expect(model.selection.laps.reference == LapID(1))
        let rows = model.readoutTable.deltaCells(atX: 3, reference: model.selection.laps.reference)
        // Now lap 1 is the baseline (no delta) and lap 0 reads against it.
        #expect(rows[0][1].delta == nil)
        #expect(rows[0][0].delta != nil)
    }

    @Test func test_set_reference_lap_selects_it_and_adds_its_column() {
        let model = makeModel() // no laps selected
        model.setReferenceLap(LapID(1))
        #expect(model.selection.laps.selected == [LapID(1)])
        #expect(model.selection.laps.reference == LapID(1))
        #expect(model.readoutTable.columns == [LapID(1)], "the reference lap becomes a column")
    }

    // MARK: - Pinned channels + formatters (large readouts)

    @Test func test_toggle_pinned_adds_then_removes_a_channel() {
        let model = makeModel()
        #expect(model.pinnedChannels.isEmpty)
        model.togglePinned(ChannelID("Speed"))
        #expect(model.pinnedChannels == [ChannelID("Speed")])
        model.togglePinned(ChannelID("Speed"))
        #expect(model.pinnedChannels.isEmpty)
    }

    @Test func test_channel_formatters_carry_the_units_and_precision() {
        let model = tableModel()
        #expect(model.channelFormatters[ChannelID("Speed")]?.unit == "km/h")
        #expect(model.channelFormatters[ChannelID("Speed")]?.precision == 1)
        #expect(model.channelFormatters[ChannelID("RPM")]?.precision == 0)
    }
}
