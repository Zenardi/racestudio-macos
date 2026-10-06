import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the anchor-preserving remap (issue 9.10): a layout is authored in a
/// 16:9 frame, and an output of another aspect (4:3, 1:1, 9:16) re-places each
/// widget so it keeps its margin to its anchor edge, keeps its shape, and stays
/// inside the 3% title-safe area.
///
/// A narrower output keeps each widget's share of the frame's width (it loses
/// height to keep its shape); a wider one keeps its share of the height. Either
/// way a widget only ever shrinks inside its authored rect, toward its anchor —
/// so a layout that doesn't overlap at 16:9 doesn't overlap in any aspect.
@Suite struct OverlayAspectResolutionTests {

    private let margin = OverlayLayout.safeMargin
    private let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)

    /// A speed readout in the bottom-left corner of the 16:9 frame.
    private let corner = NormalizedRect(x: 0.03, y: 0.82, width: 0.14, height: 0.15)

    // MARK: - Single rects

    /// At the reference aspect nothing moves, bit for bit, whatever the anchor.
    @Test(arguments: OverlayAnchor.allCases)
    func test_reference_aspect_is_the_identity(anchor: OverlayAnchor) {
        let rect = NormalizedRect(x: 0.35, y: 0.43, width: 0.29, height: 0.07)

        #expect(rect.resolved(in: .reference, anchor: anchor) == rect)
    }

    /// 16:9 → 4:3: a bottom-leading widget keeps its left and bottom margins and
    /// its share of the width, and gives up height to keep its pixel shape.
    @Test func test_4x3_keeps_the_width_share_margins_and_shape() {
        let resolved = corner.resolved(in: .standard, anchor: .bottomLeading)

        #expect(resolved.minX == 0.03)
        #expect(resolved.width == 0.14)
        #expect(abs(resolved.height - 0.15 * 0.75) < 1e-12)
        #expect(abs((1 - resolved.maxY) - 0.03) < 1e-12)
        #expect(abs(resolved.aspectRatio(in: .standard) - corner.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// A trailing widget keeps its right margin.
    @Test func test_trailing_anchor_keeps_the_right_margin() {
        let lapInfo = NormalizedRect(x: 0.75, y: 0.03, width: 0.22, height: 0.12)

        let resolved = lapInfo.resolved(in: .square, anchor: .topTrailing)

        #expect(abs((1 - resolved.maxX) - 0.03) < 1e-12)
        #expect(resolved.minY == 0.03)
    }

    /// A widget centred on an axis keeps its centre on it.
    @Test func test_centre_anchor_keeps_the_centre() {
        let gBall = NormalizedRect(x: 0.03, y: 0.4, width: 0.12, height: 0.21)

        let resolved = gBall.resolved(in: .vertical, anchor: .leading)

        #expect(abs(resolved.midY - gBall.midY) < 1e-12)
        #expect(resolved.minX == 0.03)
    }

    /// 9:16: the widget keeps its share of the (now narrow) width and its shape.
    @Test func test_vertical_keeps_the_width_share_and_shape() {
        let resolved = corner.resolved(in: .vertical, anchor: .bottomLeading)

        #expect(resolved.width == 0.14)
        #expect(abs(resolved.height - 0.15 * (9.0 / 16) / (16.0 / 9)) < 1e-12)
        #expect(abs((1 - resolved.maxY) - 0.03) < 1e-12)
        #expect(abs(resolved.aspectRatio(in: .vertical) - corner.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// An output wider than 16:9 keeps the widget's share of the height instead.
    @Test func test_a_wider_output_keeps_the_height_share() {
        let ultrawide = OverlayAspect(width: 21, height: 9)

        let resolved = corner.resolved(in: ultrawide, anchor: .bottomLeading)

        #expect(resolved.height == 0.15)
        #expect(abs(resolved.width - 0.14 * 16 / 21) < 1e-12)
        #expect(abs(resolved.aspectRatio(in: ultrawide) - corner.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// Resolved for any common output, a widget only shrinks, inside its authored
    /// rect, at its anchor offsets.
    @Test(arguments: OverlayAnchor.allCases, OverlayAspect.common)
    func test_a_widget_only_shrinks_toward_its_anchor(anchor: OverlayAnchor, aspect: OverlayAspect) {
        let rect = NormalizedRect(x: 0.4, y: 0.3, width: 0.3, height: 0.2)

        let resolved = rect.resolved(in: aspect, anchor: anchor)

        #expect(resolved.isContained(in: rect))
        #expect(abs(resolved.offsets(from: anchor).horizontal - rect.offsets(from: anchor).horizontal) < 1e-12)
        #expect(abs(resolved.offsets(from: anchor).vertical - rect.offsets(from: anchor).vertical) < 1e-12)
    }

    /// A rect too big for the safe area (one validation would have fixed)
    /// shrinks, keeping its shape, to fit.
    @Test func test_an_oversized_rect_shrinks_to_fit_keeping_its_shape() {
        let oversized = NormalizedRect(x: -0.1, y: 0.89, width: 1.2, height: 0.08)

        let resolved = oversized.resolved(in: .vertical, anchor: .bottom)

        #expect(abs(resolved.width - (1 - 2 * margin)) < 1e-12)
        #expect(resolved.isContained(in: safe))
        #expect(abs(resolved.aspectRatio(in: .vertical) - oversized.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// The editor drags in the output's frame and stores the 16:9 reference
    /// rect: mapping a resolved rect back gives the rect it came from.
    @Test(arguments: OverlayAnchor.allCases, OverlayAspect.common)
    func test_a_resolved_rect_maps_back_to_its_reference(anchor: OverlayAnchor, aspect: OverlayAspect) {
        let rect = NormalizedRect(x: 0.6, y: 0.5, width: 0.3, height: 0.2)

        let back = NormalizedRect.reference(from: rect.resolved(in: aspect, anchor: anchor), in: aspect,
                                            anchor: anchor)

        #expect(abs(back.x - rect.x) < 1e-12)
        #expect(abs(back.y - rect.y) < 1e-12)
        #expect(abs(back.width - rect.width) < 1e-12)
        #expect(abs(back.height - rect.height) < 1e-12)
    }

    /// A rect dragged past the edge in the output maps back inside the safe area.
    @Test func test_mapping_back_stays_inside_the_safe_area() {
        let dragged = NormalizedRect(x: 0.9, y: 0.95, width: 0.3, height: 0.1)

        #expect(NormalizedRect.reference(from: dragged, in: .vertical, anchor: .bottomTrailing).isContained(in: safe))
    }

    /// A rect's offsets from its anchor: the margin to a start or end edge, or
    /// the centre on a centred axis.
    @Test func test_offsets_from_the_anchor() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        #expect(rect.offsets(from: .topLeading) == OverlayAnchorOffsets(horizontal: 0.1, vertical: 0.2))
        #expect(abs(rect.offsets(from: .bottomTrailing).horizontal - 0.6) < 1e-12)
        #expect(abs(rect.offsets(from: .bottomTrailing).vertical - 0.4) < 1e-12)
        #expect(abs(rect.offsets(from: .center).horizontal - 0.25) < 1e-12)
        #expect(abs(rect.offsets(from: .center).vertical - 0.4) < 1e-12)
    }

    // MARK: - Whole layouts

    private func widget(_ id: String, z: Int, visible: Bool = true) -> OverlayWidget {
        OverlayWidget(id: id, kind: .speed, frame: NormalizedRect(x: 0.75, y: 0.03, width: 0.22, height: 0.12),
                      anchor: .topTrailing, z: z, isVisible: visible)
    }

    /// The draw list is every visible widget, back to front by `z`, ties in
    /// layout order, each in its rect for the output.
    @Test func test_resolved_layout_is_the_back_to_front_draw_list() {
        let layout = OverlayLayout(name: "Z", widgets: [widget("top", z: 5), widget("a", z: 0),
                                                        widget("hidden", z: 1, visible: false), widget("b", z: 0)])

        let resolved = layout.resolved(for: .square)

        #expect(resolved.map(\.id) == ["a", "b", "top"])
        #expect(resolved.first?.frame == layout.widgets[1].frame.resolved(in: .square, anchor: .topTrailing))
        #expect(resolved.first?.widget == layout.widgets[1])
    }

    /// A layout with *Show HUD* off draws nothing.
    @Test func test_a_disabled_layout_draws_nothing() {
        let layout = OverlayLayout(name: "Off", widgets: [widget("a", z: 0)], isEnabled: false)

        #expect(layout.resolved(for: .reference).isEmpty)
    }

    /// The draw list is made from the validated layout, so even a stray rect is
    /// drawn inside the safe area.
    @Test func test_the_draw_list_is_validated() {
        let stray = OverlayWidget(id: "s", kind: .speed, frame: NormalizedRect(x: 3, y: -1, width: 0.2, height: 0.1))

        let resolved = OverlayLayout(name: "Stray", widgets: [stray]).resolved(for: .reference)

        #expect(resolved.first?.frame.isContained(in: safe) == true)
    }

    // MARK: - Every preset × every aspect

    /// Every built-in preset, resolved for every common output, draws every
    /// widget inside the safe area, at its anchor offsets, in its shape.
    @Test(arguments: OverlayPreset.allCases, OverlayAspect.common)
    func test_every_preset_resolves_inside_the_safe_area(preset: OverlayPreset, aspect: OverlayAspect) {
        let layout = preset.layout(locale: Locale(identifier: "en"))
        let resolved = layout.resolved(for: aspect)

        #expect(resolved.count == layout.widgets.count)
        for placed in resolved {
            let source = placed.widget.frame
            let kept = placed.frame.offsets(from: placed.widget.anchor)
            let wanted = source.offsets(from: placed.widget.anchor)

            #expect(placed.frame.isContained(in: safe), "\(placed.id) leaves the safe area at \(aspect.ratio)")
            #expect(abs(kept.horizontal - wanted.horizontal) < 1e-9, "\(placed.id) drifts horizontally")
            #expect(abs(kept.vertical - wanted.vertical) < 1e-9, "\(placed.id) drifts vertically")
            #expect(abs(placed.frame.aspectRatio(in: aspect) - source.aspectRatio(in: .reference)) < 1e-9,
                    "\(placed.id) changes shape")
        }
    }

    /// No two widgets of a preset collide in any common output.
    @Test(arguments: OverlayPreset.allCases, OverlayAspect.common)
    func test_no_preset_overlaps_in_any_aspect(preset: OverlayPreset, aspect: OverlayAspect) {
        let frames = preset.layout(locale: Locale(identifier: "en")).resolved(for: aspect).map(\.frame)

        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(frame.overlapArea(with: other) < 1e-9, "\(frame) overlaps \(other) at \(aspect.ratio)")
            }
        }
    }
}
