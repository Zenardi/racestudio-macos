import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``NormalizedRect`` (issue 9.10): a widget's place in a video frame
/// as fractions of the frame (`0…1`, origin top-left, `y` down). Clamping keeps
/// any rect — off the edge, oversized, undersized or not even finite — inside
/// the title-safe area, so no widget is ever drawn off-frame.
@Suite struct NormalizedRectTests {

    private let safe = NormalizedRect.safeArea(margin: 0.03)

    /// Whether two rects agree to within rounding.
    private func approx(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        abs(lhs.x - rhs.x) < 1e-12 && abs(lhs.y - rhs.y) < 1e-12
            && abs(lhs.width - rhs.width) < 1e-12 && abs(lhs.height - rhs.height) < 1e-12
    }

    // MARK: - Geometry

    /// The edges and centre derive from origin and size.
    @Test func test_edges_and_centre() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        #expect(rect.minX == 0.1)
        #expect(rect.minY == 0.2)
        #expect(abs(rect.maxX - 0.4) < 1e-12)
        #expect(abs(rect.maxY - 0.6) < 1e-12)
        #expect(abs(rect.midX - 0.25) < 1e-12)
        #expect(abs(rect.midY - 0.4) < 1e-12)
    }

    /// The safe area is the frame inset by the margin on every side.
    @Test func test_safe_area_insets_the_frame() {
        #expect(safe == NormalizedRect(x: 0.03, y: 0.03, width: 0.94, height: 0.94))
    }

    /// A NaN or infinite component makes the rect non-finite.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func test_non_finite_components_are_detected(bad: Double) {
        #expect(!NormalizedRect(x: bad, y: 0, width: 0.1, height: 0.1).isFinite)
        #expect(!NormalizedRect(x: 0, y: 0, width: 0.1, height: bad).isFinite)
        #expect(NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1).isFinite)
    }

    /// Containment allows touching the boundary.
    @Test func test_containment() {
        #expect(NormalizedRect(x: 0.03, y: 0.03, width: 0.94, height: 0.1).isContained(in: safe))
        #expect(!NormalizedRect(x: 0.02, y: 0.5, width: 0.1, height: 0.1).isContained(in: safe))
        #expect(!NormalizedRect(x: 0.9, y: 0.5, width: 0.1, height: 0.1).isContained(in: safe))
    }

    /// The overlap of two rects is their shared area; edge contact is no overlap.
    @Test func test_overlap_area() {
        let a = NormalizedRect(x: 0, y: 0, width: 0.4, height: 0.4)

        #expect(abs(a.overlapArea(with: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4)) - 0.02) < 1e-12)
        #expect(a.overlapArea(with: NormalizedRect(x: 0.4, y: 0, width: 0.2, height: 0.2)) == 0)
        #expect(a.overlapArea(with: NormalizedRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)) == 0)
    }

    /// A rect's shape in pixels depends on the frame it sits in.
    @Test func test_pixel_aspect_ratio_depends_on_the_frame() {
        let rect = NormalizedRect(x: 0, y: 0, width: 0.18, height: 0.32)

        #expect(abs(rect.aspectRatio(in: .widescreen) - 1) < 1e-12)
        #expect(abs(rect.aspectRatio(in: .square) - 0.5625) < 1e-12)
    }

    // MARK: - Clamping

    /// A rect already inside the safe area is left exactly as it is.
    @Test func test_clamping_leaves_a_safe_rect_unchanged() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        #expect(rect.clamped(to: safe) == rect)
    }

    /// A rect on the safe edge in round numbers — `0.65 + 0.32`, one rounding
    /// error past `0.97` — is left bit for bit, so a layout snapped to a grid
    /// survives validation and round-trips exactly.
    @Test func test_clamping_leaves_a_rect_on_the_edge_within_rounding() {
        let rect = NormalizedRect(x: 0.79, y: 0.65, width: 0.18, height: 0.32)

        #expect(rect.clamped(to: safe) == rect)
    }

    /// A rect hanging off the frame moves back inside, keeping its size.
    @Test func test_clamping_moves_an_overhanging_rect_inside() {
        let rect = NormalizedRect(x: 0.9, y: -0.2, width: 0.2, height: 0.1)

        let clamped = rect.clamped(to: safe)

        #expect(abs(clamped.x - 0.77) < 1e-12)
        #expect(clamped.y == 0.03)
        #expect(clamped.width == 0.2)
        #expect(clamped.height == 0.1)
    }

    /// A rect larger than the safe area shrinks to fill it.
    @Test func test_clamping_shrinks_an_oversized_rect() {
        let rect = NormalizedRect(x: -0.5, y: 0.1, width: 2, height: 1.5)

        #expect(approx(rect.clamped(to: safe), safe))
    }

    /// An undersized rect grows to the minimum size.
    @Test func test_clamping_enforces_a_minimum_size() {
        let rect = NormalizedRect(x: 0.5, y: 0.5, width: 0.001, height: -0.2)

        let clamped = rect.clamped(to: safe, minimumSize: 0.03)

        #expect(clamped.width == 0.03)
        #expect(clamped.height == 0.03)
        #expect(clamped.x == 0.5)
    }

    /// Clamping is total: a NaN takes the region's start and an infinity its
    /// limit, so the result is always finite and inside.
    @Test func test_clamping_a_non_finite_rect_is_finite_and_inside() {
        let rect = NormalizedRect(x: .nan, y: .infinity, width: .infinity, height: .nan)

        let clamped = rect.clamped(to: safe, minimumSize: 0.03)

        #expect(clamped.isFinite)
        #expect(clamped.isContained(in: safe))
        #expect(clamped.width == 0.94)
        #expect(clamped.height == 0.03)
    }

    // MARK: - Anchors and aspects

    /// Each anchor splits into a horizontal and a vertical edge.
    @Test func test_anchor_axes() {
        #expect(OverlayAnchor.topLeading.horizontal == .start)
        #expect(OverlayAnchor.topLeading.vertical == .start)
        #expect(OverlayAnchor.bottom.horizontal == .center)
        #expect(OverlayAnchor.bottom.vertical == .end)
        #expect(OverlayAnchor.trailing.horizontal == .end)
        #expect(OverlayAnchor.trailing.vertical == .center)
        #expect(OverlayAnchor.center.horizontal == .center)
        #expect(OverlayAnchor.allCases.count == 9)
    }

    /// The output aspects are width ÷ height; an unusable size falls back to the
    /// 16:9 reference.
    @Test func test_aspect_ratios() {
        #expect(abs(OverlayAspect.widescreen.ratio - 16.0 / 9.0) < 1e-12)
        #expect(abs(OverlayAspect.standard.ratio - 4.0 / 3.0) < 1e-12)
        #expect(OverlayAspect.square.ratio == 1)
        #expect(abs(OverlayAspect.vertical.ratio - 9.0 / 16.0) < 1e-12)
        #expect(OverlayAspect.reference == .widescreen)
        #expect(OverlayAspect(width: 3840, height: 2160) == .widescreen)
        #expect(OverlayAspect(width: 0, height: 1080) == .reference)
        #expect(OverlayAspect(width: .nan, height: 1080) == .reference)
    }
}
