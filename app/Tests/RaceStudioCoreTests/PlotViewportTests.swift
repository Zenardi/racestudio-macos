import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `PlotViewport` (issue 4.1) — the zoom/pan window math.
@Suite struct PlotViewportTests {

    @Test func test_zoom_keeps_anchor_value_fixed() {
        let viewport = PlotViewport(bounds: 0...100)
        let anchor = 0.25

        let before = viewport.value(atFraction: anchor)
        let zoomed = viewport.zoom(factor: 0.5, anchor: anchor)
        let after = zoomed.value(atFraction: anchor)

        // The value under the anchor is unmoved…
        #expect(abs(after - before) < 1e-9)
        // …the span halved…
        #expect(abs(zoomed.span - 50) < 1e-9)
        // …and the window never inverts.
        #expect(zoomed.visible.lowerBound < zoomed.visible.upperBound)
        #expect(abs(zoomed.visible.lowerBound - 12.5) < 1e-9)
        #expect(abs(zoomed.visible.upperBound - 62.5) < 1e-9)
    }

    @Test func test_zoom_never_collapses_below_min_span() {
        let viewport = PlotViewport(bounds: 0...100, minSpan: 10)
        let zoomed = viewport.zoom(factor: 0.0001, anchor: 0.5)
        // Span is pinned to minSpan, not collapsed to zero.
        #expect(zoomed.span >= 10 - 1e-9)
        #expect(zoomed.span <= 10 + 1e-9)
        #expect(zoomed.visible.lowerBound < zoomed.visible.upperBound)
    }

    @Test func test_zoom_out_clamps_to_bounds() {
        let viewport = PlotViewport(bounds: 0...100)
        // Zooming out from the full extent stays at the full extent.
        let zoomed = viewport.zoom(factor: 4, anchor: 0.5)
        #expect(abs(zoomed.visible.lowerBound - 0) < 1e-9)
        #expect(abs(zoomed.visible.upperBound - 100) < 1e-9)
    }

    @Test func test_zoom_clamps_window_inside_bounds() {
        // Zooming out with the anchor at the trailing edge would push the lower
        // bound below the extent — it clamps to the left edge, keeping the span.
        let leftClamp = PlotViewport(bounds: 0...100, visible: 10...30).zoom(factor: 3, anchor: 1)
        #expect(abs(leftClamp.span - 60) < 1e-9)
        #expect(abs(leftClamp.visible.lowerBound - 0) < 1e-9)
        #expect(abs(leftClamp.visible.upperBound - 60) < 1e-9)

        // Anchor at the leading edge would push the upper bound past the extent —
        // it clamps to the right edge instead.
        let rightClamp = PlotViewport(bounds: 0...100, visible: 70...90).zoom(factor: 3, anchor: 0)
        #expect(abs(rightClamp.span - 60) < 1e-9)
        #expect(abs(rightClamp.visible.upperBound - 100) < 1e-9)
        #expect(abs(rightClamp.visible.lowerBound - 40) < 1e-9)
    }

    @Test func test_pan_shifts_domain_without_resize() {
        let viewport = PlotViewport(bounds: 0...100, visible: 25...75)

        let panned = viewport.pan(by: 10)
        #expect(abs(panned.span - 50) < 1e-9, "pan must not resize")
        #expect(abs(panned.visible.lowerBound - 35) < 1e-9)
        #expect(abs(panned.visible.upperBound - 85) < 1e-9)

        // Panning past the edge clamps but preserves the span.
        let clamped = viewport.pan(by: 1000)
        #expect(abs(clamped.span - 50) < 1e-9)
        #expect(abs(clamped.visible.upperBound - 100) < 1e-9)

        let clampedLeft = viewport.pan(by: -1000)
        #expect(abs(clampedLeft.span - 50) < 1e-9)
        #expect(abs(clampedLeft.visible.lowerBound - 0) < 1e-9)
    }

    @Test func test_reset_returns_to_full_bounds() {
        let viewport = PlotViewport(bounds: 0...100, visible: 25...75)
        let reset = viewport.reset()
        #expect(reset.visible.lowerBound == 0)
        #expect(reset.visible.upperBound == 100)
    }

    @Test func test_zoom_and_pan_ignore_nonfinite_input() {
        // A NaN/±∞ gesture value must leave the viewport unchanged, never build
        // an inverted/NaN ClosedRange (which would trap).
        let viewport = PlotViewport(bounds: 0...100, visible: 25...75)
        #expect(viewport.zoom(factor: .nan, anchor: 0.5) == viewport)
        #expect(viewport.zoom(factor: .infinity, anchor: 0.5) == viewport)
        #expect(viewport.zoom(factor: 0.5, anchor: .nan) == viewport)
        #expect(viewport.pan(by: .nan) == viewport)
        #expect(viewport.pan(by: .infinity) == viewport)
    }

    @Test func test_min_span_is_clamped_to_bounds_span() {
        // minSpan can never exceed the extent it must fit inside…
        #expect(PlotViewport(bounds: 0...10, minSpan: 100).minSpan == 10)
        // …and a degenerate extent yields a zero floor (no positive span fits).
        #expect(PlotViewport(bounds: 5...5).minSpan == 0)
    }
}
