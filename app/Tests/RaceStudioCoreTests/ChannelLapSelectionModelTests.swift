import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelLapSelectionModel` (issue 8.4) — the pure Core presentation
/// model behind the channels & laps side panel: the searchable, sortable channel
/// list with per-channel colour squares + on/off state, and the laps table with
/// best-lap highlight, invalid-lap greying, per-lap colour, and visibility state.
///
/// It is a value derived from the session's channels/laps + the shared
/// ``AnalysisSelection``, so all of the filter/sort/colour/best/invalid logic is
/// covered here FFI-free; the SwiftUI `ChannelsLapsPanelView` stays a thin binding.
@Suite struct ChannelLapSelectionModelTests {

    // MARK: - Fixture (no logic — fixed, hand-authored data)

    private func channel(_ name: String, unit: String = "") -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: 10, decimals: 0, sampleCount: 10)
    }

    /// Speed/RPM/GPS Speed/Oil Temp/Gear — chosen so alphabetical and type
    /// (by-unit) orders are both non-trivial and a dimensionless channel exists.
    private func channels() -> [Channel] {
        [channel("Speed", unit: "km/h"),
         channel("RPM", unit: "rpm"),
         channel("GPS Speed", unit: "km/h"),
         channel("Oil Temp", unit: "C"),
         channel("Gear", unit: "")]
    }

    /// Four laps: two valid (lap 1 fastest), one zero-duration (invalid), one that
    /// ties the fastest duration but comes later, so the best-lap tiebreak shows.
    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 40, endTimeS: 40),
         Lap(index: 1, startTimeS: 40, durationS: 35, endTimeS: 75),
         Lap(index: 2, startTimeS: 75, durationS: 0, endTimeS: 75),
         Lap(index: 3, startTimeS: 75, durationS: 35, endTimeS: 110)]
    }

    private func model(query: String = "", sort: ChannelSort = .configuration,
                       selection: AnalysisSelection = AnalysisSelection()) -> ChannelLapSelectionModel {
        ChannelLapSelectionModel(channels: channels(), laps: laps(),
                                 selection: selection, query: query, sort: sort)
    }

    // MARK: - ChannelSort enum

    @Test func test_channel_sort_cases_are_configuration_alphabetical_type() {
        #expect(ChannelSort.allCases == [.configuration, .alphabetical, .type])
    }

    @Test func test_channel_sort_titles_label_the_control() {
        #expect(ChannelSort.configuration.title == "Configuration")
        #expect(ChannelSort.alphabetical.title == "Alphabetical")
        #expect(ChannelSort.type.title == "Type")
    }

    @Test func test_channel_sort_id_is_the_raw_value() {
        #expect(ChannelSort.type.id == "type")
    }

    // MARK: - Channel filtering (search)

    @Test func test_empty_query_lists_every_channel() {
        #expect(model().channelRows.map(\.name)
            == ["Speed", "RPM", "GPS Speed", "Oil Temp", "Gear"])
    }

    @Test func test_query_filters_channels_by_name_case_insensitively() {
        // "sp" matches Speed and GPS Speed, in configuration order.
        #expect(model(query: "sp").channelRows.map(\.name) == ["Speed", "GPS Speed"])
        #expect(model(query: "SPEED").channelRows.map(\.name) == ["Speed", "GPS Speed"])
    }

    @Test func test_query_is_trimmed_before_matching() {
        #expect(model(query: "  speed  ").channelRows.map(\.name) == ["Speed", "GPS Speed"])
    }

    @Test func test_query_matching_nothing_yields_no_channel_rows() {
        #expect(model(query: "xyz").channelRows.isEmpty)
    }

    // MARK: - Channel sorting

    @Test func test_configuration_sort_preserves_the_decoded_order() {
        #expect(model(sort: .configuration).channelRows.map(\.name)
            == ["Speed", "RPM", "GPS Speed", "Oil Temp", "Gear"])
    }

    @Test func test_alphabetical_sort_orders_by_name_case_insensitively() {
        #expect(model(sort: .alphabetical).channelRows.map(\.name)
            == ["Gear", "GPS Speed", "Oil Temp", "RPM", "Speed"])
    }

    @Test func test_type_sort_groups_by_unit_then_name_with_dimensionless_last() {
        // Units c < km/h < rpm, then the km/h group is name-ordered, then the
        // unit-less Gear sorts last.
        #expect(model(sort: .type).channelRows.map(\.name)
            == ["Oil Temp", "GPS Speed", "Speed", "RPM", "Gear"])
    }

    @Test func test_sort_tiebreak_is_stable_on_the_configuration_index() {
        // Two channels with the same name *and* unit exhaust the alphabetical and
        // type comparisons, so both fall back to the configuration index.
        let dup = [channel("Dup", unit: "x"), channel("Dup", unit: "x")]
        func ids(_ sort: ChannelSort) -> [Int] {
            ChannelLapSelectionModel(channels: dup, laps: [], selection: AnalysisSelection(), sort: sort)
                .channelRows.map(\.id)
        }
        #expect(ids(.alphabetical) == [0, 1])
        #expect(ids(.type) == [0, 1])
    }

    @Test func test_row_id_is_the_configuration_index_stable_across_sorts() {
        func idsByName(_ sort: ChannelSort) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: model(sort: sort).channelRows.map { ($0.name, $0.id) })
        }
        // The same channel keeps its id (configuration index) whatever the sort.
        #expect(idsByName(.configuration) == idsByName(.alphabetical))
        #expect(idsByName(.configuration)["Speed"] == 0)
        #expect(idsByName(.configuration)["Gear"] == 4)
    }

    // MARK: - Channel colour + selected state

    @Test func test_unselected_channels_are_neutral_and_off() {
        let row = model().channelRows.first { $0.name == "Speed" }
        #expect(row?.isSelected == false)
        #expect(row?.color == .unselected)
    }

    @Test func test_selected_channels_take_the_palette_colour_by_selection_order() {
        let selection = AnalysisSelection(channels: [ChannelID("RPM"), ChannelID("Speed")])
        let rows = model(selection: selection).channelRows
        let rpm = rows.first { $0.name == "RPM" }
        let speed = rows.first { $0.name == "Speed" }
        #expect(rpm?.isSelected == true)
        #expect(rpm?.color == PlotColor.palette[0], "first selected → first palette colour")
        #expect(speed?.color == PlotColor.palette[1], "second selected → second palette colour")
    }

    @Test func test_channel_colour_wraps_around_the_palette() {
        // Seven channels, all selected, so the seventh wraps to palette[0].
        let seven = (0..<7).map { channel("c\($0)") }
        let selection = AnalysisSelection(channels: seven.map { ChannelID($0.name) })
        let rows = ChannelLapSelectionModel(channels: seven, laps: [], selection: selection).channelRows
        #expect(rows.last?.color == PlotColor.palette[0], "index 6 wraps to palette[0]")
    }

    @Test func test_row_exposes_the_channel_id_and_unit() {
        let row = model().channelRows.first { $0.name == "Speed" }
        #expect(row?.channel == ChannelID("Speed"))
        #expect(row?.unit == "km/h")
    }

    // MARK: - Laps: best-lap + invalid derivation

    @Test func test_best_lap_is_the_fastest_valid_lap() {
        #expect(model().bestLap == LapID(1))
    }

    @Test func test_only_the_best_lap_row_is_flagged_best() {
        let flagged = model().lapRows.filter(\.isBest).map(\.lap)
        #expect(flagged == [LapID(1)])
    }

    @Test func test_zero_duration_lap_is_invalid_and_never_best() {
        let invalid = model().lapRows.first { $0.lap == LapID(2) }
        #expect(invalid?.isValid == false)
        #expect(invalid?.isBest == false)
    }

    @Test func test_valid_laps_are_marked_valid() {
        #expect(model().lapRows.first { $0.lap == LapID(0) }?.isValid == true)
    }

    @Test func test_best_lap_tiebreak_prefers_the_earlier_lap() {
        // Laps 1 and 3 both last 35 s; the earlier (lap 1) wins.
        #expect(model().bestLap == LapID(1))
        #expect(model().lapRows.first { $0.lap == LapID(3) }?.isBest == false)
    }

    @Test func test_non_finite_duration_is_invalid_and_excluded_from_best() {
        let laps = [Lap(index: 0, startTimeS: 0, durationS: .nan, endTimeS: .nan),
                    Lap(index: 1, startTimeS: 0, durationS: 50, endTimeS: 50)]
        let m = ChannelLapSelectionModel(channels: [], laps: laps, selection: AnalysisSelection())
        #expect(m.bestLap == LapID(1), "the NaN-duration lap cannot be best")
        #expect(m.lapRows.first { $0.lap == LapID(0) }?.isValid == false)
    }

    @Test func test_no_valid_laps_leaves_best_nil_and_nothing_flagged() {
        let laps = [Lap(index: 0, startTimeS: 0, durationS: 0, endTimeS: 0),
                    Lap(index: 1, startTimeS: 0, durationS: -5, endTimeS: -5)]
        let m = ChannelLapSelectionModel(channels: [], laps: laps, selection: AnalysisSelection())
        #expect(m.bestLap == nil)
        #expect(m.lapRows.allSatisfy { !$0.isBest })
    }

    @Test func test_lap_row_number_is_one_based_and_time_is_formatted() {
        let row = model().lapRows.first { $0.lap == LapID(1) }
        #expect(row?.number == 2, "lap index 1 → number 2")
        #expect(row?.time == "0:35.000")
    }

    @Test func test_invalid_lap_time_falls_back_to_the_placeholder() {
        let laps = [Lap(index: 0, startTimeS: 0, durationS: .nan, endTimeS: .nan)]
        let m = ChannelLapSelectionModel(channels: [], laps: laps, selection: AnalysisSelection())
        #expect(m.lapRows.first?.time == LapTimeFormatter.placeholder)
    }

    // MARK: - Laps: visibility + colour

    @Test func test_visible_laps_take_the_palette_colour_by_selection_order() {
        let selection = AnalysisSelection(laps: LapSelectionModel(selected: [LapID(1), LapID(0)]))
        let rows = model(selection: selection).lapRows
        let lap1 = rows.first { $0.lap == LapID(1) }
        let lap0 = rows.first { $0.lap == LapID(0) }
        #expect(lap1?.isVisible == true)
        #expect(lap1?.color == PlotColor.palette[0])
        #expect(lap0?.color == PlotColor.palette[1])
    }

    @Test func test_hidden_laps_are_neutral_and_not_visible() {
        let row = model().lapRows.first { $0.lap == LapID(3) }
        #expect(row?.isVisible == false)
        #expect(row?.color == .unselected)
    }

    @Test func test_lap_row_id_is_the_lap_index() {
        #expect(model().lapRows.map(\.id) == [0, 1, 2, 3])
    }

    // MARK: - Empty session

    @Test func test_empty_session_has_no_rows_and_no_best_lap() {
        let m = ChannelLapSelectionModel(channels: [], laps: [], selection: AnalysisSelection())
        #expect(m.channelRows.isEmpty)
        #expect(m.lapRows.isEmpty)
        #expect(m.bestLap == nil)
    }
}
