import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the analysis window's track map following the lap selection: it
/// shows only the selected laps, asks for a selection when there is none, and
/// falls back to the whole track for a session with no laps to select.
@MainActor
@Suite struct AnalysisWindowTrackMapLapTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func channel(_ name: String) -> Channel {
        Channel(name: name, unit: "", sampleRateHz: 10, decimals: 0, sampleCount: 21)
    }

    private func lap(_ index: UInt32, from start: Double, to end: Double) -> Lap {
        Lap(index: index, startTimeS: start, durationS: end - start, endTimeS: end)
    }

    /// Three laps: 0…5 s, 5…10 s, 10…20 s.
    private func session(laps: [Lap]) -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [channel("Speed")],
            laps: laps)
    }

    private let threeLaps = [(0, 0.0, 5.0), (1, 5.0, 10.0), (2, 10.0, 20.0)]

    /// 21 GPS fixes at t = 0…20: fix `i` at `(lat: i, lon: 2·i)`, distance `10·i` m.
    private func gps() -> [GPSTrackPoint] {
        (0...20).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    private func makeModel(lapless: Bool = false) -> AnalysisWindowModel {
        let laps = lapless ? [] : threeLaps.map { lap(UInt32($0.0), from: $0.1, to: $0.2) }
        let sess = session(laps: laps)
        let bank = (0...20).map { DataSample(time: Double($0), value: Double($0)) }
        let analysis = AnalysisSession(session: sess,
                                       dataSource: FakeSessionDataSource(banks: [bank], gps: gps()))
        return AnalysisWindowModel(session: sess, analysis: analysis)
    }

    // MARK: - No selection → ask for one

    @Test func test_with_no_lap_selected_the_map_is_empty_and_asks_for_a_selection() {
        let model = makeModel()
        #expect(model.selection.laps.selected.isEmpty)
        #expect(model.trackMap.coordinates.isEmpty)
        #expect(model.trackMapNeedsLapSelection)
    }

    @Test func test_selecting_a_lap_clears_the_prompt() {
        let model = makeModel()
        model.toggleLap(LapID(1))
        #expect(!model.trackMapNeedsLapSelection)
    }

    @Test func test_deselecting_the_last_lap_brings_the_prompt_back() {
        let model = makeModel()
        model.toggleLap(LapID(1))
        model.toggleLap(LapID(1))
        #expect(model.trackMap.coordinates.isEmpty)
        #expect(model.trackMapNeedsLapSelection)
    }

    // MARK: - Selected laps only

    @Test func test_one_selected_lap_shows_only_that_lap() {
        let model = makeModel()
        model.toggleLap(LapID(1))
        #expect(model.trackMap.times == [5, 6, 7, 8, 9, 10])
    }

    @Test func test_two_selected_laps_show_both_as_separate_runs() {
        let model = makeModel()
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(2))
        #expect(model.trackMap.times.first == 0)
        #expect(model.trackMap.times.last == 20)
        #expect(!model.trackMap.times.contains(7), "lap 1 is not selected")
        #expect(model.trackMap.runStarts == [0, 6])
    }

    @Test func test_setting_a_reference_lap_selects_and_shows_it() {
        let model = makeModel()
        model.setReferenceLap(LapID(2))
        #expect(model.trackMap.times.first == 10)
    }

    @Test func test_restoring_a_project_selection_rebuilds_the_map() {
        let model = makeModel()
        model.setSelection(channelNames: ["Speed"], lapIndices: [1])
        #expect(model.trackMap.times == [5, 6, 7, 8, 9, 10])
    }

    @Test func test_marker_hides_when_the_cursor_leaves_the_selected_laps() {
        let model = makeModel()
        model.toggleLap(LapID(1))
        model.linkedCursor.moveTime(7)
        #expect(model.gpsCursorIndex == 2)
        model.linkedCursor.moveTime(15)
        #expect(model.gpsCursorIndex == nil)
    }

    @Test func test_a_selected_lap_outside_gps_coverage_is_not_reported_as_no_gps() {
        // GPS covers 0…20 s; a lap past it leaves the map empty, but the session
        // does have GPS — the panel must say so, not "no GPS data".
        let laps = threeLaps.map { lap(UInt32($0.0), from: $0.1, to: $0.2) }
            + [lap(3, from: 30, to: 40)]
        let sess = session(laps: laps)
        let bank = (0...20).map { DataSample(time: Double($0), value: Double($0)) }
        let model = AnalysisWindowModel(session: sess, analysis: AnalysisSession(
            session: sess, dataSource: FakeSessionDataSource(banks: [bank], gps: gps())))
        model.toggleLap(LapID(3))
        #expect(model.trackMap.coordinates.isEmpty)
        #expect(!model.trackMapNeedsLapSelection)
        #expect(model.hasGPSTrack)
    }

    @Test func test_a_session_without_gps_reports_no_track() {
        let sess = session(laps: threeLaps.map { lap(UInt32($0.0), from: $0.1, to: $0.2) })
        #expect(!AnalysisWindowModel(session: sess, analysis: nil).hasGPSTrack)
    }

    // MARK: - A session with no laps has nothing to select

    @Test func test_a_lapless_session_shows_the_whole_track_without_a_prompt() {
        let model = makeModel(lapless: true)
        #expect(model.trackMap.coordinates.count == 21)
        #expect(!model.trackMapNeedsLapSelection)
    }

    @Test func test_a_session_without_gps_never_asks_for_a_lap() {
        let sess = session(laps: threeLaps.map { lap(UInt32($0.0), from: $0.1, to: $0.2) })
        let model = AnalysisWindowModel(session: sess, analysis: nil)
        #expect(!model.trackMapNeedsLapSelection, "the panel says 'no GPS', not 'select a lap'")
    }
}
