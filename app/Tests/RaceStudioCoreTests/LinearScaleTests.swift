import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LinearScale` (issue 4.1) — the value↔pixel affine map.
@Suite struct LinearScaleTests {

    @Test func test_scale_map_invert_roundtrips() {
        let scale = LinearScale(domain: -12.5...87.3, range: 0...640)
        for value in stride(from: -12.5, through: 87.3, by: 3.14) {
            #expect(abs(scale.invert(scale.map(value)) - value) < 1e-9)
        }
        // Endpoints map exactly to the range edges.
        #expect(scale.map(-12.5) == 0)
        #expect(scale.map(87.3) == 640)
    }

    @Test func test_scale_clamps_out_of_range() {
        let scale = LinearScale(domain: 0...100, range: 0...200)

        // In-range values map linearly.
        #expect(scale.mapClamped(50) == 100)
        // Below/above the domain pin to the range endpoints.
        #expect(scale.mapClamped(-10) == 0)
        #expect(scale.mapClamped(150) == 200)

        // Pixels outside the range invert-clamp to the domain endpoints.
        #expect(scale.invertClamped(-20) == 0)
        #expect(scale.invertClamped(400) == 100)
        #expect(scale.invertClamped(100) == 50)

        // The unclamped map still extrapolates linearly beyond the range.
        #expect(scale.map(150) == 300)
    }

    @Test func test_scale_degenerate_domain_and_range() {
        // A zero-span domain cannot divide; map pins to the range's start.
        let flatDomain = LinearScale(domain: 5...5, range: 0...100)
        #expect(flatDomain.map(5) == 0)
        #expect(flatDomain.map(9) == 0)

        // A zero-span range cannot invert; invert pins to the domain's start.
        let flatRange = LinearScale(domain: 0...10, range: 7...7)
        #expect(flatRange.invert(7) == 0)
    }
}
