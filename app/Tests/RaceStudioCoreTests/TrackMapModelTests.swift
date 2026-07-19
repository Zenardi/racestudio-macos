import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `TrackMapModel` (issue 8.6): the pure assembly of the reused
/// `TrackMapView`'s inputs from a GPS track and an optional colour channel — the
/// racing-line coordinates + per-fix distances, the colour-by-channel values, the
/// colour scale, the lap distance, and the cursor↔fix-index mapping.
@Suite struct TrackMapModelTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    /// A track of `count` fixes: fix `i` at `(lat: i, lon: 2·i)`, distance `10·i` m,
    /// time `i` s.
    private func track(_ count: Int) -> [GPSTrackPoint] {
        (0..<count).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    // MARK: - Geometry (racing line + distances)

    @Test func test_coordinates_and_distances_come_from_the_track() {
        let model = TrackMapModel(track: track(4))
        #expect(model.coordinates == [GPSCoord(latitude: 0, longitude: 0),
                                      GPSCoord(latitude: 1, longitude: 2),
                                      GPSCoord(latitude: 2, longitude: 4),
                                      GPSCoord(latitude: 3, longitude: 6)])
        #expect(model.distances == [0, 10, 20, 30])
    }

    @Test func test_lap_distance_is_the_final_cumulative_distance() {
        #expect(TrackMapModel(track: track(4)).lapDistance == 30)
    }

    @Test func test_an_empty_track_has_no_geometry_and_a_zero_lap_distance() {
        let model = TrackMapModel(track: [])
        #expect(model.coordinates.isEmpty)
        #expect(model.distances.isEmpty)
        #expect(model.channelValues.isEmpty)
        #expect(model.lapDistance == 0)
    }

    // MARK: - Colour-by-channel

    @Test func test_channel_values_interpolate_the_colour_series_onto_each_fix() {
        // A colour channel sampled at t = 0,2 with values 0,20 → at the fix times
        // 0,1,2,3 it reads 0, 10 (interpolated), 20, 20 (clamped past the end).
        let series = ChannelSeries(xs: [0, 2], values: [0, 20])
        let model = TrackMapModel(track: track(4), colorSeries: series)
        #expect(model.channelValues == [0, 10, 20, 20])
    }

    @Test func test_colour_scale_domain_spans_the_channel_values() {
        let series = ChannelSeries(xs: [0, 3], values: [5, 35])
        let model = TrackMapModel(track: track(4), colorSeries: series)
        // Fix values are 5, 15, 25, 35 → the scale spans [5, 35] and its endpoints
        // pin to the low/high stops.
        #expect(model.colorScale.domain == 5...35)
        #expect(model.colorScale.color(for: 5) == TrackMapModel.defaultLow)
        #expect(model.colorScale.color(for: 35) == TrackMapModel.defaultHigh)
    }

    @Test func test_no_colour_channel_leaves_the_line_neutral() {
        // Without a colour series there are no per-fix values, so the view strokes
        // the whole line neutral.
        let model = TrackMapModel(track: track(4))
        #expect(model.channelValues.isEmpty)
    }

    @Test func test_an_empty_colour_series_is_treated_as_no_colour() {
        let model = TrackMapModel(track: track(4), colorSeries: ChannelSeries(xs: [], values: []))
        #expect(model.channelValues.isEmpty)
    }

    @Test func test_a_fix_with_no_readable_time_maps_to_a_neutral_value() {
        // A dropped fix (non-finite time) can't be read off the colour channel, so
        // it maps to NaN — which `ChannelColorScale` pins neutrally — while the
        // finite fixes still set the scale's domain.
        let track = [
            GPSTrackPoint(coordinate: GPSCoord(latitude: 0, longitude: 0), distance: 0, time: 0),
            GPSTrackPoint(coordinate: GPSCoord(latitude: 1, longitude: 2), distance: 10, time: .nan),
            GPSTrackPoint(coordinate: GPSCoord(latitude: 2, longitude: 4), distance: 20, time: 2)
        ]
        let model = TrackMapModel(track: track, colorSeries: ChannelSeries(xs: [0, 2], values: [0, 20]))
        #expect(model.channelValues.count == 3)
        #expect(model.channelValues[1].isNaN, "a fix with no time has no colour value")
        #expect(model.colorScale.domain == 0...20, "the finite fixes still set the scale")
    }

    // MARK: - Cursor ↔ fix-index mapping

    @Test func test_index_at_time_is_the_nearest_fix() {
        let model = TrackMapModel(track: track(5))
        #expect(model.index(atTime: 2.4) == 2, "2.4 s is nearest fix 2 (t = 2)")
        #expect(model.index(atTime: 2.6) == 3, "2.6 s is nearest fix 3 (t = 3)")
        #expect(model.index(atTime: -1) == 0, "before the start clamps to the first fix")
        #expect(model.index(atTime: 99) == 4, "after the end clamps to the last fix")
    }

    @Test func test_index_at_time_is_nil_for_an_empty_track() {
        #expect(TrackMapModel(track: []).index(atTime: 0) == nil)
    }

    @Test func test_time_at_index_returns_the_fix_time() {
        let model = TrackMapModel(track: track(5))
        #expect(model.time(atIndex: 3) == 3)
        #expect(model.time(atIndex: 99) == nil, "an out-of-range index has no time")
        #expect(model.time(atIndex: -1) == nil)
    }
}
