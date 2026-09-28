import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for how the analysis window colours and marks the selected laps on the
/// track map: by lap once two or more are selected, so overlaid racing lines can
/// be told apart, and with one position marker per lap.
@MainActor
@Suite struct AnalysisWindowTrackMapColoringTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    /// Three laps: 0…5 s, 5…10 s, 10…20 s, with 21 GPS fixes at t = 0…20.
    private func makeModel() -> AnalysisWindowModel {
        let laps = [(0, 0.0, 5.0), (1, 5.0, 10.0), (2, 10.0, 20.0)].map {
            Lap(index: UInt32($0.0), startTimeS: $0.1, durationS: $0.2 - $0.1, endTimeS: $0.2)
        }
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "Speed", unit: "", sampleRateHz: 10, decimals: 0, sampleCount: 21)],
            laps: laps)
        let gps = (0...20).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
        let bank = (0...20).map { DataSample(time: Double($0), value: Double($0)) }
        let analysis = AnalysisSession(session: session,
                                       dataSource: FakeSessionDataSource(banks: [bank], gps: gps))
        return AnalysisWindowModel(session: session, analysis: analysis)
    }

    private let speed = ChannelID("Speed")

    private func selectSpeed(_ model: AnalysisWindowModel) {
        if !model.selection.channels.contains(speed) { model.toggleChannel(speed) }
    }

    // MARK: - Colouring

    @Test func test_one_lap_is_coloured_by_the_channel() {
        let model = makeModel()
        selectSpeed(model)
        model.toggleLap(LapID(1))
        #expect(model.trackMapColoring == .channel(speed))
    }

    @Test func test_two_laps_are_coloured_by_lap_so_they_can_be_told_apart() {
        let model = makeModel()
        selectSpeed(model)
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        #expect(model.trackMapColoring == .laps)
    }

    @Test func test_with_no_channel_to_colour_by_a_lap_gets_its_own_colour() {
        let model = makeModel()
        if model.selection.channels.contains(speed) { model.toggleChannel(speed) }
        model.toggleLap(LapID(1))
        #expect(model.trackMapColoring == .laps)
    }

    @Test func test_the_users_choice_wins_over_the_automatic_one() {
        let model = makeModel()
        selectSpeed(model)
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        model.setTrackMapColoring(.channel(speed))
        #expect(model.trackMapColoring == .channel(speed), "two laps, but the user asked for the channel")
        model.setTrackMapColoring(.laps)
        model.toggleLap(LapID(2))
        #expect(model.trackMapColoring == .laps, "one lap, but the user asked for lap colours")
    }

    @Test func test_a_channel_choice_falls_back_once_the_channel_is_deselected() {
        let model = makeModel()
        selectSpeed(model)
        model.toggleLap(LapID(1))
        model.setTrackMapColoring(.channel(speed))
        model.toggleChannel(speed)
        #expect(model.trackMapColoring == .laps)
    }

    @Test func test_an_unselected_channel_cannot_be_chosen() {
        let model = makeModel()
        selectSpeed(model)
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        model.setTrackMapColoring(.channel(ChannelID("Not plotted")))
        #expect(model.trackMapColoring == .laps)
    }

    // MARK: - Lap identity and markers

    @Test func test_runs_carry_the_selection_slot_and_the_lap_number() {
        let model = makeModel()
        model.toggleLap(LapID(2))
        model.toggleLap(LapID(0))
        #expect(model.trackMap.runSlots == [1, 0], "lap 1 drawn first, but selected second")
        #expect(model.trackMap.runLapNumbers == [1, 3])
    }

    @Test func test_each_selected_lap_gets_a_marker_at_the_cursors_time_into_it() {
        let model = makeModel()
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        model.linkedCursor.moveTime(13)
        let markers = model.trackMapMarkers
        #expect(markers.count == 2)
        #expect(markers.compactMap { model.trackMap.time(atIndex: $0.index) }.sorted() == [3, 13])
        #expect(markers.first { $0.isCursorLap }?.lapNumber == 3)
    }

    @Test func test_no_markers_while_the_cursor_is_outside_the_selected_laps() {
        let model = makeModel()
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        model.linkedCursor.moveTime(7)
        #expect(model.trackMapMarkers.isEmpty)
    }
}
