import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the built-in overlay presets (issue 9.10). Each preset is pinned by
/// the structure it promises — exactly its widgets, where they are anchored —
/// and proven drawable at 16:9: valid, inside the safe area, and with no two
/// widgets on top of each other.
@Suite struct OverlayPresetsTests {

    private let en = Locale(identifier: "en")
    private let ptBR = Locale(identifier: "pt-BR")

    /// The kinds a preset holds, in layout order.
    private func kinds(_ preset: OverlayPreset) -> [OverlayWidgetKind] {
        preset.layout(locale: en).widgets.map(\.kind)
    }

    /// The anchor of each widget, by id.
    private func anchors(_ preset: OverlayPreset) -> [String: OverlayAnchor] {
        Dictionary(uniqueKeysWithValues: preset.layout(locale: en).widgets.map { ($0.id, $0.anchor) })
    }

    // MARK: - Structure

    /// Minimal: speed, the lap timer and the delta.
    @Test func test_minimal_holds_speed_lap_timer_and_delta() {
        #expect(kinds(.minimal) == [.speed, .lapTimer, .delta])
        #expect(anchors(.minimal) == ["speed": .bottomLeading, "lapTimer": .topTrailing, "delta": .top])
    }

    /// Kart coaching: speed, RPM bar, delta bar, lap info, G-ball, mini map and
    /// the kart badge.
    @Test func test_kart_coaching_holds_the_coaching_widgets() {
        #expect(kinds(.kartCoaching) == [.kartBadge, .delta, .lapInfo, .gForce, .speed, .rpm, .trackMap])
        #expect(anchors(.kartCoaching) == ["kartBadge": .topLeading, "delta": .top, "lapInfo": .topTrailing,
                                           "gForce": .bottomLeading, "speed": .bottomLeading, "rpm": .bottom,
                                           "trackMap": .bottomTrailing])
    }

    /// Full telemetry: kart coaching plus pedals, temperatures, sector times and
    /// session info.
    @Test func test_full_telemetry_adds_the_detail_widgets() {
        #expect(kinds(.fullTelemetry) == kinds(.kartCoaching) + [.sessionInfo, .sectorTimes, .temperature, .pedals])
        #expect(anchors(.fullTelemetry)["sessionInfo"] == .topLeading)
        #expect(anchors(.fullTelemetry)["sectorTimes"] == .topTrailing)
        #expect(anchors(.fullTelemetry)["temperature"] == .topTrailing)
        #expect(anchors(.fullTelemetry)["pedals"] == .bottomLeading)
    }

    /// A preset is shown, metric, in the RaceStudio theme.
    @Test(arguments: OverlayPreset.allCases)
    func test_presets_start_shown_metric_and_branded(preset: OverlayPreset) {
        let layout = preset.layout(locale: en)

        #expect(layout.isEnabled)
        #expect(layout.units == .metric)
        #expect(layout.theme == .raceStudio)
        #expect(layout.schema == OverlayLayout.currentSchema)
    }

    // MARK: - Drawable at 16:9

    /// A preset is already valid: validation leaves it untouched, so every rect is
    /// inside the safe area, at least the minimum size, and every id unique.
    @Test(arguments: OverlayPreset.allCases)
    func test_presets_are_valid(preset: OverlayPreset) {
        let layout = preset.layout(locale: en)

        #expect(layout.validated() == layout)
    }

    /// No two widgets of a preset overlap at 16:9.
    @Test(arguments: OverlayPreset.allCases)
    func test_preset_widgets_do_not_overlap(preset: OverlayPreset) {
        let frames = preset.layout(locale: en).widgets.map(\.frame)

        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] {
                #expect(frame.overlapArea(with: other) < 1e-9, "\(frame) overlaps \(other)")
            }
        }
    }

    // MARK: - Names

    /// The presets are named in the operator's language.
    @Test func test_preset_names_are_localized() {
        #expect(OverlayPreset.minimal.title(locale: en) == "Minimal")
        #expect(OverlayPreset.kartCoaching.title(locale: en) == "Kart coaching")
        #expect(OverlayPreset.fullTelemetry.title(locale: en) == "Full telemetry")
        #expect(OverlayPreset.minimal.title(locale: ptBR) == "Mínimo")
        #expect(OverlayPreset.kartCoaching.layout(locale: ptBR).name == "Treino de kart")
    }

    /// The built-ins come in menu order.
    @Test func test_built_ins_in_menu_order() {
        #expect(OverlayPreset.builtIns(locale: en).map(\.name) == ["Minimal", "Kart coaching", "Full telemetry"])
    }
}
