import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the track map's user zoom / pan (`MapViewport`): the buttons, the
/// mouse wheel, and the drags all go through it.
@Suite struct MapViewportTests {

    private let size = CGSize(width: 400, height: 200)
    private var center: CGPoint { CGPoint(x: 200, y: 100) }

    /// A fitted projection: 1000 px per degree, the centroid at the view centre.
    private func fitted() -> GeoProjection {
        GeoProjection(centroidLatitude: 10, centroidLongitude: 20, cosLatitude: 1,
                      scale: 1000, translateX: 200, translateY: 100)
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    // MARK: - Default

    @Test func test_a_fresh_viewport_leaves_the_fit_untouched() {
        let viewport = MapViewport()
        #expect(viewport.isFitted)
        #expect(viewport.apply(to: fitted(), in: size) == fitted())
    }

    // MARK: - Zoom

    @Test func test_zoom_in_magnifies_about_the_view_centre() {
        var viewport = MapViewport()
        viewport.zoomIn(in: size)
        let zoomed = viewport.apply(to: fitted(), in: size)

        #expect(zoomed.scale == 1000 * MapViewport.zoomStep)
        let centroid = GPSCoord(latitude: 10, longitude: 20)
        #expect(close(zoomed.project(centroid), center), "the view centre stays put")
    }

    @Test func test_zoom_out_undoes_zoom_in() {
        var viewport = MapViewport()
        viewport.zoomIn(in: size)
        viewport.zoomOut(in: size)
        #expect(abs(viewport.zoom - 1) < 1e-12)
    }

    @Test func test_zoom_is_clamped_at_both_ends() {
        var viewport = MapViewport()
        for _ in 0..<50 { viewport.zoomIn(in: size) }
        #expect(viewport.zoom == MapViewport.maximumZoom)
        #expect(!viewport.canZoomIn)
        for _ in 0..<50 { viewport.zoomOut(in: size) }
        #expect(viewport.zoom == MapViewport.minimumZoom)
        #expect(!viewport.canZoomOut)
    }

    @Test func test_zooming_about_a_point_keeps_the_ground_under_it() {
        // A pinch at (300, 50) must keep whatever is under the fingers there.
        var viewport = MapViewport()
        let anchor = CGPoint(x: 300, y: 50)
        let before = viewport.apply(to: fitted(), in: size).unproject(anchor)
        viewport.zoom(by: 2, anchor: anchor, in: size)
        let after = viewport.apply(to: fitted(), in: size)

        #expect(close(after.project(before), anchor))
        #expect(viewport.zoom == 2)
    }

    @Test func test_a_non_finite_or_non_positive_zoom_factor_is_ignored() {
        var viewport = MapViewport()
        viewport.zoom(by: .nan, anchor: center, in: size)
        viewport.zoom(by: 0, anchor: center, in: size)
        viewport.zoom(by: -2, anchor: center, in: size)
        #expect(viewport.isFitted)
    }

    // MARK: - Pan

    @Test func test_panning_moves_the_ground_with_the_drag() {
        var viewport = MapViewport()
        viewport.pan(by: CGSize(width: 30, height: -10), in: size)
        let panned = viewport.apply(to: fitted(), in: size)

        let centroid = GPSCoord(latitude: 10, longitude: 20)
        #expect(close(panned.project(centroid), CGPoint(x: 230, y: 90)))
    }

    @Test func test_panning_while_zoomed_follows_the_pointer_exactly() {
        var viewport = MapViewport()
        viewport.zoom(by: 4, anchor: center, in: size)
        viewport.pan(by: CGSize(width: 20, height: 0), in: size)
        let panned = viewport.apply(to: fitted(), in: size)

        let centroid = GPSCoord(latitude: 10, longitude: 20)
        #expect(close(panned.project(centroid), CGPoint(x: 220, y: 100)),
                "a 20 pt drag moves the ground 20 pt, whatever the zoom")
    }

    @Test func test_the_track_cannot_be_panned_out_of_view() {
        var viewport = MapViewport()
        viewport.pan(by: CGSize(width: 10_000, height: -10_000), in: size)
        let panned = viewport.apply(to: fitted(), in: size)

        let centroid = GPSCoord(latitude: 10, longitude: 20)
        let point = panned.project(centroid)
        #expect(point.x <= size.width && point.x >= 0, "the fitted area's edge is as far as it goes")
        #expect(point.y <= size.height && point.y >= 0)
    }

    @Test func test_a_step_pan_moves_a_fraction_of_the_view() {
        var viewport = MapViewport()
        viewport.panStep(.left, in: size)
        let panned = viewport.apply(to: fitted(), in: size)

        let centroid = GPSCoord(latitude: 10, longitude: 20)
        #expect(panned.project(centroid).x > 200, "moving the view left slides the ground right")
    }

    @Test func test_reset_returns_to_the_fit() {
        var viewport = MapViewport()
        viewport.zoomIn(in: size)
        viewport.pan(by: CGSize(width: 15, height: 15), in: size)
        viewport.reset()
        #expect(viewport.isFitted)
    }

    // MARK: - Scroll zoom

    @Test func test_rolling_the_wheel_away_zooms_in_one_notch_at_a_time() {
        #expect(MapViewport.scrollZoomFactor(delta: 1, isPrecise: false) == MapViewport.wheelNotchZoom)
        #expect(abs(MapViewport.scrollZoomFactor(delta: -1, isPrecise: false) - 1 / MapViewport.wheelNotchZoom) < 1e-12)
    }

    @Test func test_a_trackpad_scroll_zooms_smoothly_by_points() {
        let small = MapViewport.scrollZoomFactor(delta: 5, isPrecise: true)
        #expect(small > 1 && small < 1.1, "5 points is a nudge, not a notch")
        #expect(abs(MapViewport.scrollZoomFactor(delta: 70, isPrecise: true) - 2) < 0.02)
    }

    @Test func test_a_flung_wheel_cannot_jump_the_whole_zoom_range() {
        #expect(MapViewport.scrollZoomFactor(delta: 500, isPrecise: false)
                == MapViewport.scrollZoomFactor(delta: 5, isPrecise: false))
        #expect(MapViewport.scrollZoomFactor(delta: -10_000, isPrecise: true)
                == MapViewport.scrollZoomFactor(delta: -100, isPrecise: true))
    }

    @Test func test_a_non_finite_scroll_zooms_nothing() {
        #expect(MapViewport.scrollZoomFactor(delta: .nan, isPrecise: false) == 1)
        #expect(MapViewport.scrollZoomFactor(delta: .infinity, isPrecise: true) == 1)
    }

    /// Zooming with the wheel keeps the ground under the pointer where it is, so
    /// the user can zoom straight into the corner they are pointing at.
    @Test func test_wheel_zoom_keeps_the_ground_under_the_pointer() {
        var viewport = MapViewport()
        let pointer = CGPoint(x: 300, y: 50)
        let before = fitted().unproject(pointer)
        viewport.zoom(by: MapViewport.scrollZoomFactor(delta: 3, isPrecise: false), anchor: pointer, in: size)
        #expect(close(viewport.apply(to: fitted(), in: size).project(before), pointer))
    }
}
