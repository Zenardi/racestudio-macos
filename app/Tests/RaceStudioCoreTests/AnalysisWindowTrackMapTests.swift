import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisWindowModel`'s track-map panel (issue 8.6): the GPS
/// racing-line assembly, colour-by-channel selection, the sector-split count, and
/// the two-way cursor↔fix binding that keeps the map marker synced to the shared
/// ``LinkedCursor``. Covered FFI-free through a `FakeSessionDataSource`.
@MainActor
@Suite struct AnalysisWindowTrackMapTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func channel(_ name: String) -> Channel {
        Channel(name: name, unit: "", sampleRateHz: 10, decimals: 0, sampleCount: 11)
    }

    /// One lap spanning 0…10 s.
    private func session() -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [channel("Speed"), channel("RPM")],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 10, endTimeS: 10)])
    }

    /// Sample bank: sample `i` is `(time: i, value: scale·i)`.
    private func bank(_ count: Int, scale: Double) -> [DataSample] {
        (0..<count).map { DataSample(time: Double($0), value: Double($0) * scale) }
    }

    /// 11 GPS fixes at t = 0…10: fix `i` at `(lat: i, lon: 2·i)`, distance `10·i` m.
    private func gps() -> [GPSTrackPoint] {
        (0...10).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    private func makeModel(analysisPresent: Bool = true) -> AnalysisWindowModel {
        let sess = session()
        let analysis: AnalysisSession? = analysisPresent
            ? AnalysisSession(session: sess,
                              dataSource: FakeSessionDataSource(banks: [bank(11, scale: 2), bank(11, scale: 10)],
                                                                gps: gps()))
            : nil
        return AnalysisWindowModel(session: sess, analysis: analysis)
    }

    // MARK: - Racing line

    @Test func test_track_map_coordinates_come_from_the_gps_source() {
        let map = makeModel().trackMap
        #expect(map.coordinates.count == 11)
        #expect(map.coordinates.first == GPSCoord(latitude: 0, longitude: 0))
        #expect(map.coordinates.last == GPSCoord(latitude: 10, longitude: 20))
        #expect(map.lapDistance == 100)
    }

    @Test func test_track_map_is_empty_without_an_analysis_pump() {
        #expect(makeModel(analysisPresent: false).trackMap.coordinates.isEmpty)
    }

    // MARK: - Colour-by-channel

    @Test func test_colour_channel_defaults_to_the_first_selected_channel() {
        // The window opens with the first channel selected → it colours the line.
        let model = makeModel()
        #expect(model.colorChannel == ChannelID("Speed"))
        #expect(model.trackMap.channelValues.last == 20, "Speed = 2·t at t = 10")
    }

    @Test func test_set_colour_channel_recolours_the_line() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM")) // Speed + RPM selected
        model.setColorChannel(ChannelID("RPM"))
        #expect(model.colorChannel == ChannelID("RPM"))
        #expect(model.trackMap.channelValues.last == 100, "RPM = 10·t at t = 10")
    }

    @Test func test_set_colour_channel_ignores_a_channel_that_is_not_selected() {
        let model = makeModel() // only Speed selected
        model.setColorChannel(ChannelID("RPM"))
        #expect(model.colorChannel == ChannelID("Speed"), "an unselected channel cannot colour the line")
    }

    @Test func test_colour_channel_falls_back_when_the_chosen_channel_is_deselected() {
        let model = makeModel()
        model.toggleChannel(ChannelID("RPM"))
        model.setColorChannel(ChannelID("RPM"))
        model.toggleChannel(ChannelID("RPM")) // deselect the colour channel
        #expect(model.colorChannel == ChannelID("Speed"), "falls back to the first selected channel")
    }

    // MARK: - Cursor ↔ fix binding (both ways)

    @Test func test_gps_cursor_index_follows_the_shared_cursor() {
        let model = makeModel()
        model.linkedCursor.moveTime(3)
        #expect(model.gpsCursorIndex == 3)
        model.linkedCursor.moveTime(7.4)
        #expect(model.gpsCursorIndex == 7, "7.4 s is nearest fix 7")
    }

    @Test func test_move_track_cursor_to_a_fix_moves_the_shared_cursor() {
        let model = makeModel()
        model.moveTrackCursor(toFix: 4)
        #expect(model.linkedCursor.timePosition == 4)
        #expect(model.gpsCursorIndex == 4)
    }

    @Test func test_move_track_cursor_ignores_an_out_of_range_fix() {
        let model = makeModel()
        model.moveTrackCursor(toFix: 2)
        model.moveTrackCursor(toFix: 999) // out of range → no move
        #expect(model.linkedCursor.timePosition == 2)
    }

    // MARK: - Sectors

    @Test func test_sector_splits_default_to_three() {
        #expect(makeModel().sectorSplits == 3)
    }

    @Test func test_set_sector_splits_updates_and_clamps_negative_to_zero() {
        let model = makeModel()
        model.setSectorSplits(5)
        #expect(model.sectorSplits == 5)
        model.setSectorSplits(-2)
        #expect(model.sectorSplits == 0, "a negative split count hides the markers")
    }
}
