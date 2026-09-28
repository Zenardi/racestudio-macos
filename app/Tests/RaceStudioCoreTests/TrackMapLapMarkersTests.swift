import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for telling selected laps apart on the track map: each lap's run carries
/// its selection slot (its colour everywhere else) and lap number, and every lap
/// gets a position marker at the cursor's time into the lap — so the markers'
/// spread is the laps' time gap at that point.
@Suite struct TrackMapLapMarkersTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    /// 31 fixes at t = 0…30 s: fix `i` at `(lat: i, lon: 2·i)`, distance `10·i` m.
    private func track() -> [GPSTrackPoint] {
        (0...30).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    // MARK: - Run identity

    @Test func test_each_run_keeps_its_selection_slot_whatever_the_time_order() {
        // Selected lap 12…14 first, then 2…4: drawn in time order, coloured by selection.
        let map = TrackMapModel(track: track(), laps: [12...14, 2...4], lapNumbers: [5, 2])
        #expect(map.runSlots == [1, 0])
        #expect(map.runLapNumbers == [2, 5])
    }

    @Test func test_a_lap_with_no_fixes_does_not_shift_the_others_colours() {
        let map = TrackMapModel(track: track(), laps: [100...110, 2...4], lapNumbers: [9, 1])
        #expect(map.runSlots == [1], "still the second lap selected")
        #expect(map.runLapNumbers == [1])
    }

    @Test func test_missing_lap_numbers_read_as_unnumbered() {
        let map = TrackMapModel(track: track(), laps: [2...4, 12...14], lapNumbers: [3])
        #expect(map.runLapNumbers == [3, nil])
    }

    @Test func test_the_whole_track_is_one_unnumbered_run() {
        let map = TrackMapModel(track: track(), lapNumbers: [4])
        #expect(map.runSlots == [0])
        #expect(map.runLapNumbers == [nil])
    }

    // MARK: - One marker per lap

    @Test func test_every_lap_gets_a_marker_at_the_same_time_into_the_lap() throws {
        let map = TrackMapModel(track: track(), laps: [0...10, 20...30], lapNumbers: [1, 3])
        let markers = map.markers(atTime: 23)
        #expect(markers.count == 2)
        let first = try #require(markers.first { $0.slot == 0 })
        let second = try #require(markers.first { $0.slot == 1 })
        #expect(map.time(atIndex: first.index) == 3, "3 s into lap 1")
        #expect(map.time(atIndex: second.index) == 23, "the cursor itself")
        #expect(second.isCursorLap && !first.isCursorLap)
        #expect(first.lapNumber == 1)
    }

    @Test func test_a_lap_that_had_already_finished_sits_at_its_end() {
        // A 4 s lap and a 10 s lap; 7 s into the long one the short one is over.
        let map = TrackMapModel(track: track(), laps: [0...4, 10...20])
        let markers = map.markers(atTime: 17)
        let short = markers.first { $0.slot == 0 }
        #expect(short?.isBeyondLap == true)
        #expect(map.time(atIndex: short?.index ?? -1) == 4)
        #expect(markers.first { $0.slot == 1 }?.isBeyondLap == false)
    }

    @Test func test_no_markers_when_the_cursor_is_outside_every_lap() {
        let map = TrackMapModel(track: track(), laps: [0...4, 10...14])
        #expect(map.markers(atTime: 7).isEmpty)
        #expect(map.markers(atTime: .nan).isEmpty)
    }

    /// Two back-to-back laps share their boundary instant. There the cursor is at
    /// the start of the later lap, so both markers sit on a lap's start line.
    @Test func test_on_a_shared_boundary_the_cursor_starts_the_later_lap() {
        let map = TrackMapModel(track: track(), laps: [0...10, 10...20])
        let markers = map.markers(atTime: 10)
        #expect(markers.first { $0.isCursorLap }?.slot == 1)
        #expect(markers.compactMap { map.time(atIndex: $0.index) }.sorted() == [0, 10])
        #expect(markers.first { $0.slot == 1 }?.index == 11, "the later lap's own copy of the fix")
    }

    @Test func test_the_whole_track_has_a_single_uncoloured_marker() {
        let map = TrackMapModel(track: track())
        #expect(map.markers(atTime: 7) == [TrackMapMarker(index: 7, slot: nil, lapNumber: nil,
                                                          isCursorLap: true, isBeyondLap: false)])
        #expect(TrackMapModel(track: []).markers(atTime: 7).isEmpty)
    }
}
