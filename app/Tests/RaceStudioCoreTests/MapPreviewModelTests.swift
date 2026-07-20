import CoreGraphics
import Testing
@testable import RaceStudioCore

/// Behaviour for the library browser's racing-line thumbnail (issue 8.14): the
/// GPS coordinates project into the unit box (aspect preserved, north up) so the
/// view strokes a path, and a track too short to draw collapses to empty.
@Suite struct MapPreviewModelTests {

    @Test func test_no_coordinates_yields_an_empty_preview() {
        let preview = MapPreviewModel(coordinates: [])

        #expect(preview.points.isEmpty)
        #expect(preview.isEmpty)
    }

    @Test func test_single_coordinate_has_no_line_to_draw() {
        let preview = MapPreviewModel(coordinates: [GPSCoord(latitude: 45, longitude: 10)])

        #expect(preview.isEmpty)
    }

    @Test func test_projects_one_point_per_coordinate() {
        let coords = [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.1, longitude: 10.1),
            GPSCoord(latitude: 45.0, longitude: 10.2)
        ]

        let preview = MapPreviewModel(coordinates: coords)

        #expect(preview.points.count == coords.count)
        #expect(!preview.isEmpty)
    }

    @Test func test_points_stay_within_the_unit_box() {
        let coords = [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.2, longitude: 10.3),
            GPSCoord(latitude: 44.9, longitude: 10.1)
        ]

        let points = MapPreviewModel(coordinates: coords).points

        for point in points {
            #expect(point.x >= -1e-9 && point.x <= 1 + 1e-9)
            #expect(point.y >= -1e-9 && point.y <= 1 + 1e-9)
        }
    }

    @Test func test_horizontal_line_spans_the_box_width_at_mid_height() {
        // Constant latitude, increasing longitude: the fit scales longitude to
        // fill the width, and the zero-span latitude collapses to the mid-height.
        let coords = [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.0, longitude: 11.0)
        ]

        let points = MapPreviewModel(coordinates: coords).points

        #expect(abs(points[0].x - 0) < 1e-6)
        #expect(abs(points[1].x - 1) < 1e-6)
        #expect(abs(points[0].y - 0.5) < 1e-6)
        #expect(abs(points[1].y - 0.5) < 1e-6)
    }

    @Test func test_fits_into_a_custom_rect() {
        let coords = [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.0, longitude: 11.0)
        ]
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)

        let points = MapPreviewModel(coordinates: coords, in: rect).points

        #expect(abs(points[0].x - 10) < 1e-6)
        #expect(abs(points[1].x - 110) < 1e-6)
        #expect(abs(points[0].y - 40) < 1e-6) // mid-height of [20, 60]
    }
}
