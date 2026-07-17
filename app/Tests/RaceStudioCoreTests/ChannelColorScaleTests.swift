import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelColorScale` (issue 4.3) — the value→color gradient.
@Suite struct ChannelColorScaleTests {

    @Test func test_color_scale_is_monotonic_and_clamped() {
        let low = PlotColor(red: 0, green: 0, blue: 1)
        let high = PlotColor(red: 1, green: 0, blue: 0)
        let scale = ChannelColorScale(domain: 0...100, low: low, high: high)

        let c0 = scale.color(for: 0)
        let c50 = scale.color(for: 50)
        let c100 = scale.color(for: 100)

        // Ends map to the stops; the midpoint is the halfway blend.
        #expect(c0 == low)
        #expect(c100 == high)
        #expect(abs(c50.red - 0.5) < 1e-9)
        #expect(abs(c50.blue - 0.5) < 1e-9)

        // Each channel moves monotonically across the domain.
        #expect(c0.red < c50.red && c50.red < c100.red)
        #expect(c0.blue > c50.blue && c50.blue > c100.blue)

        // Out-of-range values clamp to the end stops.
        #expect(scale.color(for: -20) == low)
        #expect(scale.color(for: 200) == high)
    }

    @Test func test_color_scale_multistop_hits_each_stop() {
        let stops = [
            PlotColor(red: 0, green: 0, blue: 0),
            PlotColor(red: 0.5, green: 0.5, blue: 0.5),
            PlotColor(red: 1, green: 1, blue: 1)
        ]
        let scale = ChannelColorScale(domain: 0...10, stops: stops)
        #expect(scale.color(for: 0) == stops[0])
        #expect(scale.color(for: 5) == stops[1]) // domain midpoint = middle stop
        #expect(scale.color(for: 10) == stops[2])
    }

    @Test func test_color_scale_degenerate_domain_and_empty_stops() {
        // A zero-span domain has no gradient → the first stop everywhere.
        let flat = ChannelColorScale(domain: 5...5,
                                     low: PlotColor(red: 1, green: 0, blue: 0),
                                     high: PlotColor(red: 0, green: 1, blue: 0))
        #expect(flat.color(for: 5) == PlotColor(red: 1, green: 0, blue: 0))
        #expect(flat.color(for: 99) == PlotColor(red: 1, green: 0, blue: 0))

        // Empty stops fall back to a single neutral color (never a crash).
        let empty = ChannelColorScale(domain: 0...1, stops: [])
        #expect(empty.color(for: 0.5) == PlotColor.unselected)
    }
}
