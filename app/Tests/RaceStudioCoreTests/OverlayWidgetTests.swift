import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``OverlayWidget`` and ``OverlayWidgetKind`` (issue 9.10): what a
/// widget is called, the defaults a new one takes, and the per-widget style
/// settings that refine the layout's own.
@Suite struct OverlayWidgetTests {

    private let frame = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)

    /// Every kind has its own key, and every channel value shares one.
    @Test func test_kind_keys_are_distinct() {
        let kinds: [OverlayWidgetKind] = [.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap,
                                          .pedals, .temperature, .sectorTimes, .channelValue(.role(.rpm)),
                                          .kartBadge, .sessionInfo]

        #expect(Set(kinds.map(\.key)).count == kinds.count)
        #expect(OverlayWidgetKind.channelValue(.channel("Oil")).key == "channelValue")
        #expect(OverlayWidgetKind.gForce.key == "gForce")
    }

    /// A widget made without an id takes its kind's key; the style defaults are
    /// an opaque, translucent-plated, medium widget following the layout's units.
    @Test func test_a_new_widget_takes_the_defaults() {
        let widget = OverlayWidget(kind: .trackMap, frame: frame)

        #expect(widget.id == "trackMap")
        #expect(widget.anchor == .topLeading)
        #expect(widget.z == 0)
        #expect(widget.opacity == 1)
        #expect(widget.plate == .translucent)
        #expect(widget.sizeClass == .medium)
        #expect(widget.units == nil)
        #expect(widget.isVisible)
        #expect(widget.options == OverlayWidgetOptions())
    }

    /// The size class scales a widget's text within its rect.
    @Test func test_size_classes_scale_text() {
        #expect(OverlaySizeClass.small.textScale < OverlaySizeClass.medium.textScale)
        #expect(OverlaySizeClass.medium.textScale == 1)
        #expect(OverlaySizeClass.large.textScale > OverlaySizeClass.medium.textScale)
    }

    /// A widget shows the layout's units unless it sets its own.
    @Test func test_a_widget_may_override_the_layout_units() {
        let inherits = OverlayWidget(id: "a", kind: .speed, frame: frame)
        let imperial = OverlayWidget(id: "b", kind: .speed, frame: frame, units: .imperial)
        let layout = OverlayLayout(name: "Units", widgets: [inherits, imperial], units: .metric)

        #expect(layout.units(for: inherits) == .metric)
        #expect(layout.units(for: imperial) == .imperial)
    }
}
