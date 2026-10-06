import Testing
import Foundation
import CoreGraphics

@testable import RaceStudioCore

/// Tests for `TrackPosition` (issue 9.9): where on the mini map the kart is at
/// a session instant, in the unit map frame the library preview and the track
/// map use (`GeoProjection` fitted with `framingTrim`, north up), plus its
/// direction of travel.
@Suite struct TrackPositionTests {

    // MARK: - Fixtures

    /// Three laps round a ~220 m-diameter circle, 200 fixes (20 s) a lap at
    /// 10 Hz, starting due north of the centre and running clockwise; a 2 s
    /// cool-down trail heads off the circuit to the east afterwards.
    private func circuit() -> (track: [GPSTrackPoint], laps: [Lap]) {
        let radius = 0.001
        var track: [GPSTrackPoint] = []
        for step in 0..<600 {
            let theta = 2 * Double.pi * Double(step) / 200
            let coord = GPSCoord(latitude: 45 + radius * cos(theta),
                                 longitude: 12 + radius * sin(theta) / cos(45 * Double.pi / 180))
            track.append(GPSTrackPoint(coordinate: coord, distance: Double(step), time: Double(step) / 10))
        }
        for step in 0..<20 {
            let coord = GPSCoord(latitude: 45 + radius, longitude: 12 + 0.0002 * Double(step))
            track.append(GPSTrackPoint(coordinate: coord, distance: 600 + Double(step), time: 60 + Double(step) / 10))
        }
        let laps = (0..<3).map { Lap(index: UInt32($0), startTimeS: Double($0) * 20, durationS: 20,
                                     endTimeS: Double($0 + 1) * 20) }
        return (track, laps)
    }

    /// A box walked north, east, south, west, a pause, then north again.
    private func box() -> [GPSTrackPoint] {
        let corners = [(45.0, 12.0), (45.0001, 12.0), (45.0001, 12.0001), (45.0, 12.0001),
                       (45.0, 12.0), (45.0, 12.0), (45.0001, 12.0)]
        return corners.enumerated().map { index, corner in
            GPSTrackPoint(coordinate: GPSCoord(latitude: corner.0, longitude: corner.1),
                          distance: 0, time: Double(index) / 10)
        }
    }

    // MARK: - Framing

    /// The racing line is the best lap's fixes framed exactly as the library
    /// preview frames them — the same points, so the mini map and the preview
    /// show the same picture.
    @Test func test_racing_line_is_the_library_preview_line() {
        let (track, laps) = circuit()

        let position = TrackPosition(track: track, laps: laps)

        let coordinates = SessionPreview.bestLapCoordinates(laps, track: track)
        #expect(position.racingLine == MapPreviewModel(coordinates: coordinates).points)
        #expect(position.projection == GeoProjection.fit(to: coordinates, trimmingFraction: GeoProjection.framingTrim))
    }

    /// Given an on-circuit fix, then the kart's position is that fix projected
    /// by the track map's projection — and lies inside the unit frame.
    @Test func test_on_circuit_positions_match_the_projection_inside_the_unit_frame() throws {
        let (track, laps) = circuit()
        let position = TrackPosition(track: track, laps: laps)

        for fix in track.prefix(600) {
            let reading = try #require(position.reading(at: fix.time))
            #expect(reading.point == position.projection.project(fix.coordinate))
            #expect((-1e-9...1 + 1e-9).contains(reading.point.x), "x at \(fix.time)")
            #expect((-1e-9...1 + 1e-9).contains(reading.point.y), "y at \(fix.time)")
        }
    }

    /// Between two fixes the position moves along the straight segment joining
    /// their projections.
    @Test func test_position_interpolates_between_fixes() throws {
        let (track, laps) = circuit()
        let position = TrackPosition(track: track, laps: laps)
        let before = position.projection.project(track[10].coordinate)
        let after = position.projection.project(track[11].coordinate)

        let reading = try #require(position.reading(at: 1.05))

        #expect(abs(reading.point.x - (before.x + after.x) / 2) < 1e-9)
        #expect(abs(reading.point.y - (before.y + after.y) / 2) < 1e-9)
    }

    // MARK: - Heading

    /// Heading is the direction of travel along the current segment, in degrees
    /// clockwise from north; a stationary kart keeps the heading it had.
    @Test func test_heading_follows_the_direction_of_travel() throws {
        let position = TrackPosition(track: box(), laps: [])

        let expected: [(Double, Double)] = [(0.05, 0), (0.15, 90), (0.25, 180), (0.35, 270), (0.45, 270), (0.55, 0)]
        for (t, heading) in expected {
            let reading = try #require(position.reading(at: t)?.heading, "t \(t)")
            #expect(abs(reading - heading) < 1e-6, "t \(t)")
        }
    }

    /// A kart that sits still before it first moves already faces the way it
    /// sets off.
    @Test func test_a_stationary_start_takes_the_first_heading() throws {
        let start = (0..<3).map { GPSTrackPoint(coordinate: GPSCoord(latitude: 45, longitude: 12),
                                                distance: 0, time: Double($0) / 10) }
        let off = GPSTrackPoint(coordinate: GPSCoord(latitude: 45, longitude: 12.0001), distance: 0, time: 0.3)

        let reading = try #require(TrackPosition(track: start + [off], laps: []).reading(at: 0.05)?.heading)

        #expect(abs(reading - 90) < 1e-6, "it sets off east")
    }

    /// A kart that never moves has no direction of travel.
    @Test func test_a_kart_that_never_moves_has_no_heading() throws {
        let still = (0..<5).map { GPSTrackPoint(coordinate: GPSCoord(latitude: 45, longitude: 12),
                                                distance: 0, time: Double($0) / 10) }

        let reading = try #require(TrackPosition(track: still, laps: []).reading(at: 0.2))

        #expect(reading.heading == nil)
    }

    // MARK: - Missing data

    /// Outside the fixes, inside a GPS gap, or with no GPS at all, there is no
    /// position.
    @Test func test_no_fix_means_no_position() {
        let (track, laps) = circuit()
        let gapped = Array(track[0..<100]) + Array(track[110..<200])
        let position = TrackPosition(track: gapped, laps: laps)
        let noGPS = TrackPosition(track: [], laps: laps)

        #expect(position.reading(at: -0.1) == nil)
        #expect(position.reading(at: 10.4) == nil, "a 1.1 s GPS gap")
        #expect(position.reading(at: 25) == nil)
        #expect(noGPS.isEmpty)
        #expect(noGPS.racingLine.isEmpty)
        #expect(noGPS.reading(at: 1) == nil)
    }

    // MARK: - Hints

    /// Property: hinted reads over a forward sweep equal fresh reads.
    @Test func test_hinted_reads_equal_fresh_reads() {
        let (track, laps) = circuit()
        let position = TrackPosition(track: track, laps: laps)
        var hint = 0

        for t in stride(from: -1.0, to: 63, by: 0.0333) {
            #expect(position.reading(at: t, hint: &hint) == position.reading(at: t), "t \(t)")
        }
    }
}
