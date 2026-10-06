import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the anchor-preserving remap (issue 9.10): a layout is authored in a
/// 16:9 frame, and an output of another aspect (4:3, 1:1, 9:16) re-places each
/// widget so it keeps its margin to its anchor edge, keeps its shape, and stays
/// inside the 3% title-safe area.
///
/// Sizes follow the frame's short side: a widget is as many pixels tall in a
/// 1920×1080 frame as it is wide-and-tall in a 1080×1920 one.
@Suite struct OverlayAspectResolutionTests {

    private let margin = OverlayLayout.safeMargin
    private let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)

    /// A speed readout in the bottom-left corner of the 16:9 frame.
    private let corner = NormalizedRect(x: 0.03, y: 0.82, width: 0.14, height: 0.15)

    // MARK: - Single rects

    /// At the reference aspect nothing moves, whatever the anchor.
    @Test(arguments: OverlayAnchor.allCases)
    func test_reference_aspect_is_the_identity(anchor: OverlayAnchor) {
        let rect = NormalizedRect(x: 0.35, y: 0.4, width: 0.3, height: 0.07)

        let resolved = rect.resolved(in: .reference, anchor: anchor)

        #expect(abs(resolved.x - rect.x) < 1e-12)
        #expect(abs(resolved.y - rect.y) < 1e-12)
        #expect(abs(resolved.width - rect.width) < 1e-12)
        #expect(abs(resolved.height - rect.height) < 1e-12)
    }

    /// 16:9 → 4:3: a bottom-leading widget keeps its left and bottom margins,
    /// keeps its height (the short side is still the height) and grows wider in
    /// normalized terms so its pixel shape is unchanged.
    @Test func test_4x3_bottom_leading_keeps_margins_and_shape() {
        let resolved = corner.resolved(in: .standard, anchor: .bottomLeading)

        #expect(abs(resolved.minX - 0.03) < 1e-12)
        #expect(abs((1 - resolved.maxY) - 0.03) < 1e-12)
        #expect(abs(resolved.height - 0.15) < 1e-12)
        #expect(abs(resolved.aspectRatio(in: .standard) - corner.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// A trailing widget keeps its right margin.
    @Test func test_trailing_anchor_keeps_the_right_margin() {
        let lapInfo = NormalizedRect(x: 0.75, y: 0.03, width: 0.22, height: 0.12)

        let resolved = lapInfo.resolved(in: .square, anchor: .topTrailing)

        #expect(abs((1 - resolved.maxX) - 0.03) < 1e-12)
        #expect(abs(resolved.minY - 0.03) < 1e-12)
    }

    /// A centred widget keeps its centre.
    @Test func test_centre_anchor_keeps_the_centre() {
        let delta = NormalizedRect(x: 0.35, y: 0.03, width: 0.3, height: 0.07)

        let resolved = delta.resolved(in: .standard, anchor: .top)

        #expect(abs(resolved.midX - 0.5) < 1e-12)
        #expect(abs(resolved.minY - 0.03) < 1e-12)
    }

    /// 9:16: the short side is the width, so the widget keeps its pixel size
    /// relative to it and its shape.
    @Test func test_vertical_keeps_shape_relative_to_the_short_side() {
        let resolved = corner.resolved(in: .vertical, anchor: .bottomLeading)

        #expect(abs(resolved.width - 0.14 * 16 / 9) < 1e-12)
        #expect(abs(resolved.height - 0.15 * 9 / 16) < 1e-12)
        #expect(abs((1 - resolved.maxY) - 0.03) < 1e-12)
        #expect(abs(resolved.aspectRatio(in: .vertical) - corner.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// A widget too wide for the vertical frame shrinks, keeping its shape, to
    /// fit the safe width.
    @Test func test_an_oversized_widget_shrinks_to_fit_keeping_its_shape() {
        let rpmBar = NormalizedRect(x: 0.2, y: 0.89, width: 0.6, height: 0.08)

        let resolved = rpmBar.resolved(in: .vertical, anchor: .bottom)

        #expect(abs(resolved.width - (1 - 2 * margin)) < 1e-12)
        #expect(resolved.isContained(in: safe))
        #expect(abs(resolved.aspectRatio(in: .vertical) - rpmBar.aspectRatio(in: .widescreen)) < 1e-9)
    }

    /// A centred widget that grows past the frame edge is pushed back inside the
    /// safe area.
    @Test func test_a_grown_centred_widget_is_kept_inside_the_safe_area() {
        let banner = NormalizedRect(x: 0.03, y: 0.03, width: 0.3, height: 0.07)

        let resolved = banner.resolved(in: .standard, anchor: .top)

        #expect(abs(resolved.minX - 0.03) < 1e-12)
        #expect(resolved.isContained(in: safe))
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

    /// Every built-in preset, resolved for every common output, keeps each widget
    /// inside the safe area, at its anchor offsets, in its shape.
    @Test(arguments: OverlayPreset.allCases, OverlayAspect.common)
    func test_every_preset_resolves_inside_the_safe_area(preset: OverlayPreset, aspect: OverlayAspect) {
        let layout = preset.layout(locale: Locale(identifier: "en"))

        for placed in layout.resolved(for: aspect) {
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
}
