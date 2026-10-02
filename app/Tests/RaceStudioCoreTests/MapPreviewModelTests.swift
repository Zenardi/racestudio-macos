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

    // MARK: - Fitting into the view (the stretched-thumbnail fix)

    /// A track twice as wide (east-west) as it is tall, at the equator so a
    /// degree of longitude and of latitude cover the same ground.
    private static let wideTrack = [
        GPSCoord(latitude: 0.0, longitude: 0.0),
        GPSCoord(latitude: 0.0, longitude: 0.002),
        GPSCoord(latitude: 0.001, longitude: 0.002),
        GPSCoord(latitude: 0.001, longitude: 0.0)
    ]

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    @Test func test_fitted_track_keeps_its_shape_in_a_wide_box() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)

        let box = Self.bounds(preview.fitted(in: CGRect(x: 0, y: 0, width: 800, height: 100), inset: 10))

        #expect(abs(box.width / box.height - 2) < 0.01)
    }

    @Test func test_fitted_track_keeps_its_shape_in_a_tall_box() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)

        let box = Self.bounds(preview.fitted(in: CGRect(x: 0, y: 0, width: 100, height: 800), inset: 10))

        #expect(abs(box.width / box.height - 2) < 0.01)
    }

    @Test func test_fitted_track_fills_the_limiting_side_inside_the_inset() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)

        let box = Self.bounds(preview.fitted(in: CGRect(x: 0, y: 0, width: 800, height: 100), inset: 10))

        #expect(abs(box.height - 80) < 0.01)
        #expect(abs(box.width - 160) < 0.01)
    }

    @Test func test_fitted_track_is_centred_in_the_box() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)
        let rect = CGRect(x: 20, y: 30, width: 800, height: 100)

        let box = Self.bounds(preview.fitted(in: rect, inset: 10))

        #expect(abs(box.midX - rect.midX) < 0.01)
        #expect(abs(box.midY - rect.midY) < 0.01)
    }

    @Test func test_fitted_straight_line_spans_the_width_at_mid_height() {
        let preview = MapPreviewModel(coordinates: [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.0, longitude: 10.01)
        ])

        let points = preview.fitted(in: CGRect(x: 0, y: 0, width: 200, height: 100), inset: 10)

        #expect(abs(points[0].x - 10) < 0.01)
        #expect(abs(points[1].x - 190) < 0.01)
        #expect(abs(points[0].y - 50) < 0.01)
    }

    @Test func test_fitted_keeps_one_point_per_fix_in_order() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)

        let points = preview.fitted(in: CGRect(x: 0, y: 0, width: 300, height: 200), inset: 0)

        #expect(points.count == Self.wideTrack.count)
        #expect(points[0].x < points[1].x)
    }

    @Test func test_empty_preview_fits_to_no_points() {
        let preview = MapPreviewModel(coordinates: [])

        #expect(preview.fitted(in: CGRect(x: 0, y: 0, width: 300, height: 200), inset: 10).isEmpty)
    }

    @Test func test_box_smaller_than_the_inset_fits_to_no_points() {
        let preview = MapPreviewModel(coordinates: Self.wideTrack)

        #expect(preview.fitted(in: CGRect(x: 0, y: 0, width: 15, height: 15), inset: 10).isEmpty)
    }

    // MARK: - Framing the circuit, not a stray trail

    /// A 200-fix circle (the circuit) after a 6-fix drive ending far to the
    /// south — about 3% of the fixes, the share a logger left running on the
    /// way in gave on a real session (523 of 14,920 fixes, up to 766 m out).
    private static func circuitWithTrail() -> [GPSCoord] {
        let trail = (0..<6).map { i in
            GPSCoord(latitude: -0.05 + Double(i) * 0.008, longitude: 0.0)
        }
        let circuit = (0..<200).map { i -> GPSCoord in
            let angle = Double(i) / 200 * 2 * Double.pi
            return GPSCoord(latitude: 0.001 * sin(angle), longitude: 0.001 * cos(angle))
        }
        return trail + circuit
    }

    @Test func test_a_stray_trail_does_not_shrink_the_circuit() {
        let preview = MapPreviewModel(coordinates: Self.circuitWithTrail())

        let fitted = preview.fitted(in: CGRect(x: 0, y: 0, width: 800, height: 200), inset: 10)
        let circuit = Self.bounds(Array(fitted.suffix(200)))

        #expect(circuit.height > 170) // fills the 180-pt available height
    }

    @Test func test_a_framed_circuit_keeps_its_shape() {
        let preview = MapPreviewModel(coordinates: Self.circuitWithTrail())

        let fitted = preview.fitted(in: CGRect(x: 0, y: 0, width: 800, height: 200), inset: 10)
        let circuit = Self.bounds(Array(fitted.suffix(200)))

        #expect(abs(circuit.width / circuit.height - 1) < 0.05)
    }

    @Test func test_a_stray_trail_is_left_out_of_the_drawn_runs() {
        let preview = MapPreviewModel(coordinates: Self.circuitWithTrail())

        let runs = preview.visibleRuns(in: CGRect(x: 0, y: 0, width: 800, height: 200), inset: 10)

        #expect(runs.map(\.count).reduce(0, +) <= 201) // the circuit, at most one trail fix
        #expect(runs.allSatisfy { run in run.allSatisfy { $0.y >= -0.5 && $0.y <= 200.5 } })
    }

    @Test func test_a_clean_circuit_is_drawn_whole() {
        let circuit = Array(Self.circuitWithTrail().suffix(200))
        let preview = MapPreviewModel(coordinates: circuit)

        let runs = preview.visibleRuns(in: CGRect(x: 0, y: 0, width: 800, height: 200), inset: 10)

        #expect(runs.count == 1)
        #expect(runs.first?.count == 200)
    }

    @Test func test_north_is_up() {
        let preview = MapPreviewModel(coordinates: [
            GPSCoord(latitude: 45.000, longitude: 10.0),
            GPSCoord(latitude: 45.001, longitude: 10.0)
        ])

        let points = preview.fitted(in: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 10)

        #expect(points[1].y < points[0].y)
    }

    @Test func test_vertical_line_spans_the_height_at_mid_width() {
        let preview = MapPreviewModel(coordinates: [
            GPSCoord(latitude: 45.000, longitude: 10.0),
            GPSCoord(latitude: 45.001, longitude: 10.0)
        ])

        let points = preview.fitted(in: CGRect(x: 0, y: 0, width: 300, height: 100), inset: 10)

        #expect(abs(points[0].y - 90) < 0.01)
        #expect(abs(points[1].y - 10) < 0.01)
        #expect(abs(points[0].x - 150) < 0.01)
    }

    @Test func test_frame_is_the_unit_box_for_a_clean_square() {
        let preview = MapPreviewModel(coordinates: [
            GPSCoord(latitude: 0.0, longitude: 0.0),
            GPSCoord(latitude: 0.001, longitude: 0.001)
        ])

        #expect(abs(preview.frame.width - 1) < 1e-6)
        #expect(abs(preview.frame.height - 1) < 1e-6)
    }

    @Test func test_identical_fixes_have_nothing_to_draw() {
        let spot = GPSCoord(latitude: 45, longitude: 10)
        let preview = MapPreviewModel(coordinates: [spot, spot, spot])

        #expect(preview.isEmpty)
        #expect(preview.fitted(in: CGRect(x: 0, y: 0, width: 100, height: 100), inset: 10).isEmpty)
    }
}
