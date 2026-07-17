import Testing
import Foundation
import CoreGraphics
@testable import RaceStudioCore

/// Tests for `GeoProjection` (issue 4.3) — the auto-fit equirectangular map
/// projection.
@Suite struct GeoProjectionTests {

    /// A rectangle of corners centered on latitude 60° (so `cos = 0.5` exactly),
    /// twice as wide (cos-adjusted longitude) as it is tall.
    private let corners = [
        GPSCoord(latitude: 59.99, longitude: 10.00),
        GPSCoord(latitude: 59.99, longitude: 10.08),
        GPSCoord(latitude: 60.01, longitude: 10.00),
        GPSCoord(latitude: 60.01, longitude: 10.08)
    ]
    private let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private struct GpsGolden: Decodable { let channels: [GpsChannel] }
    private struct GpsChannel: Decodable { let name: String; let min: Double; let max: Double }

    @Test func test_projection_fits_extremes_to_bounds() throws {
        let projection = GeoProjection.fit(to: corners, in: unitRect)
        let points = corners.map(projection.project)
        let xs = points.map(\.x)
        let ys = points.map(\.y)

        // The wider (longitude) axis is limiting, so it fills the rect exactly…
        #expect(abs(try #require(xs.min()) - 0) < 1e-9)
        #expect(abs(try #require(xs.max()) - 1) < 1e-9)
        // …and every point stays inside the rect.
        #expect(ys.allSatisfy { $0 >= -1e-9 && $0 <= 1 + 1e-9 })

        // North (max latitude) maps to the top (smaller y).
        let north = projection.project(GPSCoord(latitude: 60.01, longitude: 10.04))
        let south = projection.project(GPSCoord(latitude: 59.99, longitude: 10.04))
        #expect(north.y < south.y)
    }

    @Test func test_projection_preserves_aspect_ratio() throws {
        let projection = GeoProjection.fit(to: corners, in: unitRect)
        let points = corners.map(projection.project)
        let width = try #require(points.map(\.x).max()) - (try #require(points.map(\.x).min()))
        let height = try #require(points.map(\.y).max()) - (try #require(points.map(\.y).min()))

        // The cos-adjusted longitude span is 2× the latitude span, so the fitted
        // width is 2× the height — the racing line is not stretched.
        #expect(abs(width - 1.0) < 1e-9)
        #expect(abs(height - 0.5) < 1e-9)
    }

    @Test func test_single_point_projection_no_divide_by_zero() {
        let single = [GPSCoord(latitude: 45.0, longitude: 12.0)]
        let projection = GeoProjection.fit(to: single, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let point = projection.project(single[0])

        #expect(point.x.isFinite && point.y.isFinite)
        // A degenerate (single-point) set collapses to the rect center.
        #expect(abs(point.x - 50) < 1e-9)
        #expect(abs(point.y - 50) < 1e-9)

        // Empty input is also safe (no NaN).
        let empty = GeoProjection.fit(to: [], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(empty.project(GPSCoord(latitude: 0, longitude: 0)).x.isFinite)
    }

    @Test func test_projection_fits_real_gps_bounds() throws {
        let golden: GpsGolden = try FixtureLoader.golden("aim_official_test", aspect: "gps")
        let lat = try #require(golden.channels.first { $0.name == "GPS Latitude" })
        let lon = try #require(golden.channels.first { $0.name == "GPS Longitude" })
        let bounds = [
            GPSCoord(latitude: lat.min, longitude: lon.min),
            GPSCoord(latitude: lat.min, longitude: lon.max),
            GPSCoord(latitude: lat.max, longitude: lon.min),
            GPSCoord(latitude: lat.max, longitude: lon.max)
        ]
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let projection = GeoProjection.fit(to: bounds, in: rect)
        let points = bounds.map(projection.project)

        #expect(points.allSatisfy {
            $0.x >= -1e-6 && $0.x <= 400 + 1e-6 && $0.y >= -1e-6 && $0.y <= 400 + 1e-6
        })
        // The limiting axis touches both edges of the target rect.
        let minX = try #require(points.map(\.x).min())
        let maxX = try #require(points.map(\.x).max())
        let minY = try #require(points.map(\.y).min())
        let maxY = try #require(points.map(\.y).max())
        let touchesX = abs(minX) < 1e-6 && abs(maxX - 400) < 1e-6
        let touchesY = abs(minY) < 1e-6 && abs(maxY - 400) < 1e-6
        #expect(touchesX || touchesY)
    }
}
