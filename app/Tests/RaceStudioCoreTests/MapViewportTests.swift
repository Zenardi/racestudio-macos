import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the track map's user zoom / pan (`MapViewport`) and for capping a
/// projection at the zoom the map imagery can actually show.
///
/// Why the cap exists: MapKit will not zoom in past roughly 0.54 m per point on
/// satellite imagery. Asked for a tighter region it silently shows a wider one, so a
/// ~200 m kart circuit filling a large pane was drawn about 2x larger than the
/// ground under it. The line must be drawn at the scale the map really shows.
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

    // MARK: - Capping at what the imagery can show

    @Test func test_limit_zoom_lowers_but_never_raises_the_zoom() {
        var viewport = MapViewport()
        viewport.zoom(by: 4, anchor: center, in: size)
        viewport.limitZoom(to: 2.5)
        #expect(viewport.zoom == 2.5)
        viewport.limitZoom(to: 8)
        #expect(viewport.zoom == 2.5, "a looser limit does not zoom back in")
    }

    @Test func test_a_projection_under_the_limit_is_unchanged() {
        #expect(fitted().limited(toScale: 5000, about: center) == fitted())
    }

    @Test func test_a_projection_over_the_limit_is_scaled_down_about_the_centre() {
        let limited = fitted().limited(toScale: 400, about: center)
        #expect(limited.scale == 400)
        let centroid = GPSCoord(latitude: 10, longitude: 20)
        #expect(close(limited.project(centroid), center), "the map keeps its centre when it widens")
    }

    @Test func test_a_non_finite_or_non_positive_limit_is_ignored() {
        #expect(fitted().limited(toScale: .nan, about: center) == fitted())
        #expect(fitted().limited(toScale: 0, about: center) == fitted())
    }

    @Test func test_a_regions_scale_is_the_view_height_per_degree_of_latitude() {
        let region = GeoRegion(center: GPSCoord(latitude: 0, longitude: 0),
                               latitudeDelta: 0.002, longitudeDelta: 0.004)
        #expect(region.scale(forHeight: 200) == 100_000)
        #expect(region.scale(forHeight: 0) == nil)
    }

    // MARK: - Reading the imagery's limit off what MapKit shows

    private func request() -> GeoProjection {
        // 0.24 m/pt at San Marino, centred in a 400x200 view.
        GeoProjection(centroidLatitude: -22.777, centroidLongitude: -47.12,
                      cosLatitude: cos(-22.777 * .pi / 180),
                      scale: 111_320 / 0.24, translateX: 200, translateY: 100)
    }

    @Test func test_a_widened_region_reveals_the_limit() throws {
        let shown = GeoRegion(center: GPSCoord(latitude: -22.777, longitude: -47.12),
                              latitudeDelta: 200 * 0.54 / 111_320, longitudeDelta: 0.002)
        let limit = try #require(shown.zoomLimit(forRequest: request(), in: size))
        #expect(abs(limit - 111_320 / 0.54) < 1e-6)
    }

    @Test func test_the_region_that_was_asked_for_reveals_no_limit() throws {
        let asked = try #require(GeoRegion.covering(request(), size: size))
        #expect(asked.zoomLimit(forRequest: request(), in: size) == nil)
    }

    /// A map not laid out yet reports a whole-world region. Taken as a limit it
    /// would shrink the line to nothing, so it must be ignored.
    @Test func test_an_unsettled_whole_world_region_is_not_a_limit() {
        let world = GeoRegion(center: GPSCoord(latitude: -22.777, longitude: -47.12),
                              latitudeDelta: 90, longitudeDelta: 180)
        #expect(world.zoomLimit(forRequest: request(), in: size) == nil)
    }

    /// MapKit widens about the centre it was given; a region somewhere else is a
    /// stale report from before the last request, not a limit.
    @Test func test_an_off_centre_region_is_not_a_limit() {
        let stale = GeoRegion(center: GPSCoord(latitude: -22.770, longitude: -47.12),
                              latitudeDelta: 200 * 0.54 / 111_320, longitudeDelta: 0.002)
        #expect(stale.zoomLimit(forRequest: request(), in: size) == nil)
    }

    @Test func test_no_limit_is_read_off_an_empty_view() {
        let shown = GeoRegion(center: GPSCoord(latitude: -22.777, longitude: -47.12),
                              latitudeDelta: 0.001, longitudeDelta: 0.002)
        #expect(shown.zoomLimit(forRequest: request(), in: .zero) == nil)
    }

    /// The real case: the fit asks for 0.24 m/pt, MapKit shows 0.54 m/pt. Drawn
    /// through the limit, a 200 m circuit spans the pixels the imagery gives it.
    @Test func test_drawing_through_the_maps_limit_matches_the_imagery_scale() throws {
        let metresPerDegree = 111_320.0
        let fit = GeoProjection(centroidLatitude: -22.777, centroidLongitude: -47.12,
                                cosLatitude: cos(-22.777 * .pi / 180),
                                scale: metresPerDegree / 0.24, translateX: 200, translateY: 100)
        let mapRegion = GeoRegion(center: GPSCoord(latitude: -22.777, longitude: -47.12),
                                  latitudeDelta: 200 * 0.54 / metresPerDegree, longitudeDelta: 0.002)
        let limit = try #require(mapRegion.scale(forHeight: 200))

        let drawn = fit.limited(toScale: limit, about: center)
        let north = drawn.project(GPSCoord(latitude: -22.777 + 200 / metresPerDegree, longitude: -47.12))
        let south = drawn.project(GPSCoord(latitude: -22.777, longitude: -47.12))
        #expect(abs(abs(north.y - south.y) - 200 / 0.54) < 1e-6, "200 m at 0.54 m/pt")
    }
}
