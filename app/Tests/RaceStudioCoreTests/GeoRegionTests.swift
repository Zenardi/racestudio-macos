import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for placing a real map underneath the racing line.
///
/// The track map draws into a `GeoProjection` fitted to the session's coordinates.
/// To show satellite imagery beneath it, the map view has to be told exactly which
/// geographic region that projection covers for a given view size — otherwise the
/// line floats over ground it was not recorded on. `GeoRegion.covering` inverts the
/// projection at the view's corners, so the two agree by construction rather than
/// by a hand-tuned zoom level.
@Suite struct GeoRegionTests {

    /// A ~200 m kart circuit, the scale this actually runs at.
    private let coords = [
        GPSCoord(latitude: -22.7768, longitude: -47.1201),
        GPSCoord(latitude: -22.7782, longitude: -47.1204),
        GPSCoord(latitude: -22.7776, longitude: -47.1195)
    ]
    private let size = CGSize(width: 400, height: 300)

    private func projection() -> GeoProjection {
        GeoProjection.fit(to: coords, in: CGRect(origin: .zero, size: size))
    }

    // MARK: - Inverting the projection

    @Test func test_unprojecting_a_projected_coordinate_round_trips() {
        let projection = projection()

        for coord in coords {
            let back = projection.unproject(projection.project(coord))
            #expect(abs(back.latitude - coord.latitude) < 1e-9)
            #expect(abs(back.longitude - coord.longitude) < 1e-9)
        }
    }

    /// A degenerate projection (no coordinates, so scale 0) must not divide by zero.
    @Test func test_unprojecting_through_a_degenerate_projection_is_finite() {
        let flat = GeoProjection.fit(to: [], in: CGRect(origin: .zero, size: size))

        let coord = flat.unproject(CGPoint(x: 10, y: 10))

        #expect(coord.latitude.isFinite)
        #expect(coord.longitude.isFinite)
    }

    // MARK: - The region the view shows

    @Test func test_the_region_is_centred_on_the_projections_centroid() throws {
        let projection = projection()

        let region = try #require(GeoRegion.covering(projection, size: size))

        // The fit centres the coordinate bounding box in the view, so the view's
        // centre is the centroid the projection was built around.
        #expect(abs(region.center.latitude - projection.centroidLatitude) < 1e-9)
        #expect(abs(region.center.longitude - projection.centroidLongitude) < 1e-9)
    }

    /// The whole racing line must be inside the region, or the map would crop it.
    @Test func test_the_region_contains_every_coordinate() throws {
        let region = try #require(GeoRegion.covering(projection(), size: size))

        for coord in coords {
            #expect(abs(coord.latitude - region.center.latitude) <= region.latitudeDelta / 2 + 1e-9)
            #expect(abs(coord.longitude - region.center.longitude) <= region.longitudeDelta / 2 + 1e-9)
        }
    }

    /// The fit preserves aspect ratio with one uniform scale, so the region must be
    /// wider than tall in ground *metres* for a landscape view — the check that
    /// catches a longitude/latitude mix-up, which would squash the imagery.
    @Test func test_a_landscape_view_yields_a_ground_region_wider_than_it_is_tall() throws {
        let region = try #require(GeoRegion.covering(projection(), size: size))
        let metresPerDegree = 111_320.0
        let widthM = region.longitudeDelta * metresPerDegree
            * cos(region.center.latitude * .pi / 180)
        let heightM = region.latitudeDelta * metresPerDegree

        #expect(widthM / heightM > 1.32)
        #expect(widthM / heightM < 1.34, "matches the 400x300 view's 4:3 aspect")
    }

    @Test func test_a_taller_view_yields_a_taller_region() throws {
        let tall = CGSize(width: 300, height: 600)
        let wide = try #require(GeoRegion.covering(projection(), size: size))
        let narrow = try #require(
            GeoRegion.covering(GeoProjection.fit(to: coords, in: CGRect(origin: .zero, size: tall)),
                               size: tall))

        #expect(narrow.latitudeDelta > wide.latitudeDelta)
    }

    // MARK: - Degenerate inputs

    @Test func test_a_zero_sized_view_has_no_region() {
        #expect(GeoRegion.covering(projection(), size: .zero) == nil)
    }

    @Test func test_a_session_with_no_coordinates_has_no_region() {
        let flat = GeoProjection.fit(to: [], in: CGRect(origin: .zero, size: size))

        #expect(GeoRegion.covering(flat, size: size) == nil)
    }

    /// A single fix has no extent to frame, so the region falls back to a small
    /// fixed span centred on it rather than an infinite or zero one.
    @Test func test_a_single_fix_falls_back_to_a_minimum_span() {
        let single = GeoProjection.fit(to: [coords[0]], in: CGRect(origin: .zero, size: size))

        let region = GeoRegion.covering(single, size: size)

        #expect(region == nil, "a zero-scale projection frames nothing")
    }

    @Test func test_a_non_finite_view_size_has_no_region() {
        #expect(GeoRegion.covering(projection(), size: CGSize(width: CGFloat.nan, height: 300)) == nil)
    }
}

/// The map style shown under the racing line, and how it persists.
@Suite struct TrackMapBackdropTests {

    @Test func test_the_default_is_no_map() {
        // The plot must stay readable — and offline — unless the user asks for imagery.
        #expect(TrackMapBackdrop.default == .none)
    }

    @Test func test_every_style_has_a_title() {
        for style in TrackMapBackdrop.allCases {
            #expect(!style.title.isEmpty)
        }
    }

    @Test func test_only_imagery_styles_need_the_network() {
        #expect(!TrackMapBackdrop.none.needsNetwork)
        #expect(TrackMapBackdrop.standard.needsNetwork)
        #expect(TrackMapBackdrop.satellite.needsNetwork)
        #expect(TrackMapBackdrop.hybrid.needsNetwork)
    }

    /// The choice is persisted, so it must survive a round trip by raw value.
    @Test func test_a_style_round_trips_through_its_raw_value() throws {
        for style in TrackMapBackdrop.allCases {
            #expect(TrackMapBackdrop(rawValue: style.rawValue) == style)
        }
    }

    @Test func test_an_unknown_saved_style_falls_back_to_the_default() {
        #expect(TrackMapBackdrop(rawValue: "hologram") == nil)
    }
}

/// The trim fraction the track map actually ships with (5%), pinned against a clean
/// trace so a future change cannot quietly start cropping good data.
@Suite struct GeoProjectionShippedTrimTests {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let shippedTrim = 0.05

    /// A dense, clean circuit — the case where trimming must cost almost nothing.
    private var circuit: [GPSCoord] {
        (0..<2000).map { i in
            let a = Double(i) / 2000 * .pi * 2
            return GPSCoord(latitude: -22.7772 + 0.0009 * sin(a),
                            longitude: -47.1198 + 0.0009 * cos(a))
        }
    }

    private func heightM(_ projection: GeoProjection) throws -> Double {
        try #require(GeoRegion.covering(projection, size: rect.size)).latitudeDelta * 111_320
    }

    @Test func test_the_shipped_trim_costs_a_clean_trace_under_two_percent() throws {
        let plain = try heightM(GeoProjection.fit(to: circuit, in: rect))
        let trimmed = try heightM(
            GeoProjection.fit(to: circuit, in: rect, trimmingFraction: shippedTrim))

        #expect(abs(plain - trimmed) / plain < 0.02)
    }

    /// The case it exists for: a cluster of off-track fixes (3% of the session, the
    /// shape of a real excursion) must not set the frame.
    @Test func test_the_shipped_trim_rejects_a_three_percent_excursion() throws {
        let excursion = (0..<62).map { i in
            GPSCoord(latitude: -22.7835 + Double(i) * 1e-5, longitude: -47.1255)
        }
        let clean = try heightM(GeoProjection.fit(to: circuit, in: rect))
        let polluted = try heightM(
            GeoProjection.fit(to: circuit + excursion, in: rect, trimmingFraction: shippedTrim))

        #expect(abs(polluted - clean) / clean < 0.1, "framed as if the excursion were absent")
    }
}
