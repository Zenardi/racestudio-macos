import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the track map's still imagery: which ground is fetched, and where a
/// fetched image is placed so its ground lies under the racing line at any zoom.
///
/// The imagery used to be a live MapKit view, which will not zoom past ~0.54 m per
/// point and silently showed a wider region, so the line and the ground drew at
/// different scales. A snapshot placed by two known coordinates is scaled with the
/// line instead, and cannot drift from it.
@Suite struct MapImageryTests {

    private let metresPerDegree = 111_320.0

    /// A 200 m x 100 m circuit at the equator (so a degree is the same both ways).
    private func circuit() -> GeoRegion {
        GeoRegion(center: GPSCoord(latitude: 0, longitude: 10),
                  latitudeDelta: 100 / metresPerDegree, longitudeDelta: 200 / metresPerDegree)
    }

    // MARK: - What to fetch

    @Test func test_a_coarse_then_a_fine_square_around_the_circuit() throws {
        let requests = MapImagery.requests(framing: circuit())
        try #require(requests.count == 2)
        #expect(requests.map { Double($0.size.width) } == [MapImagery.contextSize, MapImagery.detailSize])
        let context = requests[0].region, detail = requests[1].region
        #expect(abs(detail.latitudeDelta * metresPerDegree - 200 * MapImagery.detailCoverage) < 1e-6,
                "a square on the circuit's longer side")
        #expect(abs(detail.longitudeDelta - detail.latitudeDelta) < 1e-12, "square at the equator")
        #expect(abs(context.latitudeDelta * metresPerDegree - 200 * MapImagery.contextCoverage) < 1e-6)
        #expect(context.center == circuit().center && detail.center == circuit().center)
    }

    @Test func test_longitude_widens_away_from_the_equator_to_stay_square_on_the_ground() throws {
        let region = GeoRegion(center: GPSCoord(latitude: 60, longitude: 10),
                               latitudeDelta: 0.001, longitudeDelta: 0.001)
        let detail = try #require(MapImagery.requests(framing: region).last).region
        #expect(abs(detail.longitudeDelta - detail.latitudeDelta * 2) < 1e-9, "cos 60° = 1/2")
    }

    @Test func test_a_single_point_still_gets_a_neighbourhood() throws {
        let point = GeoRegion(center: GPSCoord(latitude: 0, longitude: 0), latitudeDelta: 0, longitudeDelta: 0)
        let detail = try #require(MapImagery.requests(framing: point).last).region
        #expect(abs(detail.latitudeDelta * metresPerDegree - MapImagery.minimumExtent * MapImagery.detailCoverage)
                < 1e-6)
    }

    @Test func test_a_non_finite_region_fetches_nothing() {
        let bad = GeoRegion(center: GPSCoord(latitude: 0, longitude: 0), latitudeDelta: .nan, longitudeDelta: 1)
        #expect(MapImagery.requests(framing: bad).isEmpty)
    }

    // MARK: - Where it goes

    /// 1000 px per degree, the point (0, 10) drawn at (500, 400).
    private func projection(scale: Double = 1000) -> GeoProjection {
        GeoProjection(centroidLatitude: 0, centroidLongitude: 10, cosLatitude: 1,
                      scale: scale, translateX: 500, translateY: 400)
    }

    /// A 100 x 80 image whose south-west anchor (−0.01, 9.99) is at (20, 70) and
    /// north-east anchor (0.01, 10.01) at (80, 10) — y counted down.
    private func tile() -> MapImagery.Tile {
        MapImagery.Tile(size: CGSize(width: 100, height: 80),
                        southWest: GPSCoord(latitude: -0.01, longitude: 9.99), southWestPoint: CGPoint(x: 20, y: 70),
                        northEast: GPSCoord(latitude: 0.01, longitude: 10.01), northEastPoint: CGPoint(x: 80, y: 10))
    }

    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    @Test func test_both_anchors_land_where_the_projection_draws_them() throws {
        let frame = try #require(tile().frame(in: projection()))
        // The anchors span 20 px of view for 60 px of image across, and 20 for 60 up.
        let sx = frame.width / 100, sy = frame.height / 80
        let southWest = projection().project(tile().southWest)
        let northEast = projection().project(tile().northEast)
        #expect(close(frame.minX + 20 * sx, southWest.x) && close(frame.minY + 70 * sy, southWest.y))
        #expect(close(frame.minX + 80 * sx, northEast.x) && close(frame.minY + 10 * sy, northEast.y))
    }

    /// The fix for the mismatch: zooming 4x scales the image 4x with the line, so
    /// the ground under a fix stays under it.
    @Test func test_zooming_scales_the_image_with_the_line() throws {
        let fitted = try #require(tile().frame(in: projection()))
        let zoomed = try #require(tile().frame(in: projection(scale: 4000)))
        #expect(close(zoomed.width, fitted.width * 4) && close(zoomed.height, fitted.height * 4))
    }

    @Test func test_a_tile_with_coincident_anchors_cannot_be_placed() {
        let flat = MapImagery.Tile(size: CGSize(width: 10, height: 10),
                                   southWest: GPSCoord(latitude: 0, longitude: 0), southWestPoint: .zero,
                                   northEast: GPSCoord(latitude: 1, longitude: 1), northEastPoint: .zero)
        #expect(flat.frame(in: projection()) == nil)
    }

    @Test func test_a_degenerate_projection_places_nothing() {
        let collapsed = GeoProjection(centroidLatitude: 0, centroidLongitude: 0, cosLatitude: 1,
                                      scale: 0, translateX: 0, translateY: 0)
        #expect(tile().frame(in: collapsed) == nil)
    }

    // MARK: - The ground the view frames

    @Test func test_the_framed_region_ignores_a_stray_excursion_like_the_fit() throws {
        // 40 fixes on a small loop, then one 5 km away.
        var coords = (0..<40).map { GPSCoord(latitude: Double($0 % 10) * 1e-4, longitude: Double($0 / 10) * 1e-4) }
        coords.append(GPSCoord(latitude: 0.05, longitude: 0.05))
        let trimmed = try #require(GeoProjection.framedRegion(of: coords, trimmingFraction: 0.05))
        let plain = try #require(GeoProjection.framedRegion(of: coords))
        #expect(trimmed.latitudeDelta < 1e-3, "the loop, not the excursion")
        #expect(plain.latitudeDelta > 0.04)
        #expect(GeoProjection.framedRegion(of: []) == nil)
    }
}
