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

    /// Kart coaching: speed, RPM bar, delta bar, the running lap time, lap info,
    /// G-ball, mini map, the kart badge and the sector splits.
    @Test func test_kart_coaching_holds_the_coaching_widgets() {
        #expect(kinds(.kartCoaching) == [.kartBadge, .delta, .lapTimer, .lapInfo, .gForce, .speed, .rpm, .trackMap,
                                         .sectorTimes])
        #expect(anchors(.kartCoaching) == ["kartBadge": .topLeading, "delta": .top, "lapTimer": .topTrailing,
                                           "lapInfo": .topTrailing, "gForce": .bottomLeading,
                                           "speed": .bottom, "rpm": .bottom, "trackMap": .bottomTrailing,
                                           "sectorTimes": .topLeading])
    }

    /// Kart coaching and Full telemetry (issue 9.17): the sector splits sit in
    /// the top-left corner, in one column with the kart badge, right under it —
    /// or under session info, in Full telemetry — and the same size in both.
    @Test(arguments: [(OverlayPreset.kartCoaching, OverlayWidgetKind.kartBadge), (.fullTelemetry, .sessionInfo)])
    func test_the_sector_splits_sit_top_left(preset: OverlayPreset, above: OverlayWidgetKind) throws {
        let widgets = preset.layout(locale: en).widgets
        let splits = try #require(widgets.first { $0.kind == .sectorTimes })
        let over = try #require(widgets.first { $0.kind == above })
        let reference = try #require(OverlayPreset.kartCoaching.layout(locale: en).widgets
            .first { $0.kind == .sectorTimes })

        #expect(splits.anchor == .topLeading)
        #expect(abs(splits.frame.x - over.frame.x) < 1e-9 && abs(splits.frame.width - over.frame.width) < 1e-9,
                "one column with the \(above)")
        #expect(over.frame.y + over.frame.height <= splits.frame.y, "under the \(above)")
        #expect(splits.frame.y - (over.frame.y + over.frame.height) <= 0.02, "right under it")
        #expect(splits.frame.width == reference.frame.width && splits.frame.height == reference.frame.height)
    }

    /// Kart coaching and Full telemetry (issue 9.15): speed and RPM are needle
    /// dials side by side at the bottom centre — round, the same size and
    /// close together, like a car's instrument cluster.
    @Test(arguments: [OverlayPreset.kartCoaching, .fullTelemetry])
    func test_speed_and_rpm_are_a_cluster_of_round_dials(preset: OverlayPreset) throws {
        let widgets = preset.layout(locale: en).widgets
        let speed = try #require(widgets.first { $0.kind == .speed })
        let rpm = try #require(widgets.first { $0.kind == .rpm })

        #expect(speed.options.gaugeStyle == .needle && rpm.options.gaugeStyle == .needle)
        for dial in [speed, rpm] {
            #expect(abs(dial.frame.width * 16 - dial.frame.height * 9) < 1e-9, "\(dial.id) is round at 16:9")
            #expect(dial.anchor == .bottom)
        }
        #expect(speed.frame.width == rpm.frame.width && speed.frame.y == rpm.frame.y, "the same size, level")
        #expect(speed.frame.x + speed.frame.width <= rpm.frame.x, "speed on the left")
        #expect(rpm.frame.x - (speed.frame.x + speed.frame.width) <= 0.02, "close together")
        #expect(abs((speed.frame.x + rpm.frame.x + rpm.frame.width) / 2 - 0.5) < 1e-9, "centred")
    }

    /// Minimal keeps the speed as digits.
    @Test func test_minimal_keeps_the_speed_digits() throws {
        let speed = try #require(OverlayPreset.minimal.layout(locale: en).widgets.first { $0.kind == .speed })

        #expect(speed.options.gaugeStyle == .classic)
    }

    /// Kart coaching and Full telemetry (issue 9.16): the running lap time sits
    /// at the top of the right corner, larger than a lap-info row, with lap info
    /// right under it in the same column.
    @Test(arguments: [OverlayPreset.kartCoaching, .fullTelemetry])
    func test_the_running_lap_time_tops_the_right_corner_above_lap_info(preset: OverlayPreset) throws {
        let widgets = preset.layout(locale: en).widgets
        let timer = try #require(widgets.first { $0.kind == .lapTimer })
        let info = try #require(widgets.first { $0.kind == .lapInfo })
        let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)

        #expect(timer.anchor == .topTrailing)
        #expect(abs(timer.frame.y - safe.y) < 1e-9, "at the top of the safe area")
        #expect(abs(timer.frame.x - info.frame.x) < 1e-9 && abs(timer.frame.width - info.frame.width) < 1e-9,
                "one column with lap info")
        #expect(timer.frame.y + timer.frame.height <= info.frame.y, "above lap info")
        #expect(info.frame.y - (timer.frame.y + timer.frame.height) <= 0.02, "right above it")
        #expect(timer.frame.height > info.frame.height / 3, "larger than a lap-info row")
    }

    /// Full telemetry: kart coaching plus pedals, temperatures and session info,
    /// with the sector splits under session info.
    @Test func test_full_telemetry_adds_the_detail_widgets() {
        #expect(kinds(.fullTelemetry) == [.kartBadge, .delta, .lapTimer, .lapInfo, .gForce, .speed, .rpm, .trackMap,
                                          .sessionInfo, .sectorTimes, .temperature, .pedals])
        #expect(Set(kinds(.kartCoaching)).isSubset(of: Set(kinds(.fullTelemetry))))
        #expect(anchors(.fullTelemetry)["sessionInfo"] == .topLeading)
        #expect(anchors(.fullTelemetry)["sectorTimes"] == .topLeading)
        #expect(anchors(.fullTelemetry)["temperature"] == .topTrailing)
        #expect(anchors(.fullTelemetry)["pedals"] == .bottomLeading)
    }

    /// Kart coaching and Full telemetry (issue 9.18): the G-ball is taller than
    /// wide in pixels, so its numbers fit under a ball as wide as the widget.
    @Test(arguments: [OverlayPreset.kartCoaching, .fullTelemetry])
    func test_the_g_ball_has_room_for_its_numbers(preset: OverlayPreset) throws {
        let ball = try #require(preset.layout(locale: en).widgets.first { $0.kind == .gForce })

        #expect(ball.frame.height * 9 > ball.frame.width * 16, "taller than wide at 16:9")
        #expect(ball.anchor == .bottomLeading)
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
