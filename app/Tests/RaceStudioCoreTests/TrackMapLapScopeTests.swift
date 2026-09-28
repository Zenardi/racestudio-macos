import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for scoping `TrackMapModel` to the selected laps: only fixes inside a
/// selected lap's time window are kept, each lap is its own run (so the map
/// never strokes a line from one lap's end to another's start), the sector marks
/// measure along a single lap, and the cursor marker hides outside the laps.
@Suite struct TrackMapLapScopeTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    /// 21 fixes at t = 0…20 s: fix `i` at `(lat: i, lon: 2·i)`, distance `10·i` m.
    private func track() -> [GPSTrackPoint] {
        (0...20).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    // MARK: - Filtering

    @Test func test_without_lap_windows_the_whole_track_is_one_run() {
        let map = TrackMapModel(track: track())
        #expect(map.coordinates.count == 21)
        #expect(map.runStarts == [0])
    }

    @Test func test_a_single_lap_keeps_only_its_fixes() {
        let map = TrackMapModel(track: track(), laps: [5...10])
        #expect(map.times == [5, 6, 7, 8, 9, 10])
        #expect(map.coordinates.first == GPSCoord(latitude: 5, longitude: 10))
        #expect(map.runStarts == [0])
    }

    @Test func test_each_lap_is_its_own_run_so_no_line_joins_them() {
        let map = TrackMapModel(track: track(), laps: [2...4, 12...14])
        #expect(map.times == [2, 3, 4, 12, 13, 14])
        #expect(map.runStarts == [0, 3], "lap 12…14 starts a new run at index 3")
    }

    @Test func test_contiguous_laps_share_their_boundary_fix_but_stay_separate_runs() {
        // Lap A ends at 4 s exactly where lap B starts; both keep that fix so each
        // lap is drawn closed, and B still starts its own run.
        let map = TrackMapModel(track: track(), laps: [2...4, 4...6])
        #expect(map.times == [2, 3, 4, 4, 5, 6])
        #expect(map.runStarts == [0, 3])
    }

    @Test func test_laps_are_drawn_in_time_order_whatever_the_selection_order() {
        let map = TrackMapModel(track: track(), laps: [12...14, 2...4])
        #expect(map.times == [2, 3, 4, 12, 13, 14])
    }

    @Test func test_empty_lap_windows_give_an_empty_map() {
        let map = TrackMapModel(track: track(), laps: [])
        #expect(map.coordinates.isEmpty)
        #expect(map.runStarts.isEmpty)
        #expect(map.lapDistance == 0)
    }

    @Test func test_a_lap_with_no_gps_fixes_adds_no_run() {
        let map = TrackMapModel(track: track(), laps: [100...110, 2...4])
        #expect(map.times == [2, 3, 4])
        #expect(map.runStarts == [0])
    }

    @Test func test_a_dropped_fix_is_left_out_of_a_lap() {
        var points = track()
        points[3] = GPSTrackPoint(coordinate: points[3].coordinate, distance: points[3].distance, time: .nan)
        let map = TrackMapModel(track: points, laps: [2...4])
        #expect(map.times == [2, 4])
    }

    // MARK: - Sectors measure one lap

    @Test func test_sector_distances_are_the_first_lap_rebased_to_zero() {
        let map = TrackMapModel(track: track(), laps: [2...4, 12...15])
        #expect(map.sectorDistances == [0, 10, 20], "fixes 2…4 at 20…40 m, rebased")
        #expect(map.lapDistance == 20, "one lap's length, not the session's")
    }

    @Test func test_whole_session_sector_distances_are_rebased_too() {
        let map = TrackMapModel(track: track())
        #expect(map.sectorDistances.first == 0)
        #expect(map.lapDistance == 200)
    }

    // MARK: - Colour scale spans the selected laps only

    @Test func test_colour_scale_spans_only_the_selected_laps() {
        let series = ChannelSeries(xs: (0...20).map(Double.init), values: (0...20).map { Double($0) * 3 })
        let map = TrackMapModel(track: track(), colorSeries: series, laps: [5...10])
        #expect(map.channelValues == [15, 18, 21, 24, 27, 30])
        #expect(map.colorScale.domain == 15...30)
    }

    // MARK: - Cursor

    @Test func test_cursor_inside_a_lap_maps_to_its_fix() {
        let map = TrackMapModel(track: track(), laps: [2...4, 12...14])
        #expect(map.index(atTime: 13) == 4)
        #expect(map.time(atIndex: 4) == 13)
    }

    @Test func test_cursor_outside_every_selected_lap_has_no_marker() {
        // Snapping the marker to the nearest selected lap would show the car
        // somewhere it was not at that moment.
        let map = TrackMapModel(track: track(), laps: [2...4, 12...14])
        #expect(map.index(atTime: 8) == nil)
        #expect(map.index(atTime: 20) == nil)
    }

    @Test func test_cursor_on_a_lap_boundary_still_has_a_marker() {
        let map = TrackMapModel(track: track(), laps: [2...4])
        #expect(map.index(atTime: 4) == 2)
        #expect(map.index(atTime: 2) == 0)
    }
}
