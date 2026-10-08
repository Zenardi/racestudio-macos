import Foundation
import Testing
@testable import RaceStudioCore

/// The gauge style of the RPM and speed widgets (issue 9.15): `classic` — the
/// RPM bar and the speed digits — or `needle` dials. A widget saved before the
/// style existed keeps the classic look; the editor switches it, and a needle
/// speedometer adds its full scale to the widget's options.
@MainActor
@Suite struct OverlayGaugeStyleTests {

    private func decode(_ json: String) throws -> OverlayWidgetOptions {
        try JSONDecoder().decode(OverlayWidgetOptions.self, from: Data(json.utf8))
    }

    // MARK: - Persistence

    @Test func test_options_saved_before_the_style_keep_the_classic_look() throws {
        let options = try decode(#"{"maxRPM": 12000}"#)

        #expect(options.gaugeStyle == .classic)
        #expect(options.maxSpeed == OverlayWidgetOptions.defaultMaxSpeed)
    }

    @Test func test_a_needle_style_and_max_speed_round_trip() throws {
        let options = OverlayWidgetOptions(gaugeStyle: .needle, maxSpeed: 130)

        let back = try JSONDecoder().decode(OverlayWidgetOptions.self, from: JSONEncoder().encode(options))

        #expect(back == options)
    }

    @Test func test_an_unknown_style_reads_as_classic() throws {
        #expect(try decode(#"{"gaugeStyle": "hologram"}"#).gaugeStyle == .classic)
    }

    /// Max speed is clamped to what a dial can draw; a non-finite one takes the
    /// default. The style survives validation.
    @Test func test_max_speed_is_validated() {
        let limits = OverlayWidgetOptions.maxSpeedLimits

        #expect(OverlayWidgetOptions(maxSpeed: 1e6).validated().maxSpeed == limits.upperBound)
        #expect(OverlayWidgetOptions(maxSpeed: 1).validated().maxSpeed == limits.lowerBound)
        #expect(OverlayWidgetOptions(maxSpeed: .nan).validated().maxSpeed == OverlayWidgetOptions.defaultMaxSpeed)
        #expect(OverlayWidgetOptions(gaugeStyle: .needle).validated().gaugeStyle == .needle)
    }

    // MARK: - Drawing

    /// The style picks what draws the widget; other kinds ignore it.
    @Test func test_the_style_picks_the_drawer() {
        let needle = OverlayWidgetOptions(gaugeStyle: .needle)

        #expect(OverlayWidgetKind.rpm.drawer(for: OverlayWidgetOptions()) is RPMWidget)
        #expect(OverlayWidgetKind.rpm.drawer(for: needle) is TachometerWidget)
        #expect(OverlayWidgetKind.speed.drawer(for: OverlayWidgetOptions()) is SpeedWidget)
        #expect(OverlayWidgetKind.speed.drawer(for: needle) is SpeedometerWidget)
        #expect(OverlayWidgetKind.gear.drawer(for: needle) is GearWidget)
    }

    // MARK: - The editor

    @Test func test_only_rpm_and_speed_offer_a_gauge_style() {
        let kinds: [OverlayWidgetKind] = [.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap,
                                          .pedals, .temperature, .sectorTimes, .kartBadge, .sessionInfo]

        #expect(kinds.filter(\.offersGaugeStyle) == [.speed, .rpm])
    }

    /// A needle speedometer offers its full scale; the speed digits have
    /// nothing to set, and the RPM widget's settings serve both its styles.
    @Test func test_a_needle_speedometer_offers_its_max_speed() {
        var speed = OverlayWidget(kind: .speed, frame: .unit)
        #expect(speed.editableOptions.isEmpty)

        speed.options.gaugeStyle = .needle

        #expect(speed.editableOptions == [.maxSpeed])
        #expect(OverlayWidget(kind: .rpm, frame: .unit).editableOptions == [.maxRPM, .shiftLightRPM])
    }

    @Test func test_switching_the_style_is_one_undoable_step() {
        let editor = OverlayEditorFixture.editor()

        editor.setGaugeStyle(.needle, for: "speed")

        #expect(editor.layout.widgets.first { $0.id == "speed" }?.options.gaugeStyle == .needle)
        editor.undo()
        #expect(editor.layout.widgets.first { $0.id == "speed" }?.options.gaugeStyle == .classic)
    }

    @Test func test_the_style_and_max_speed_are_named_in_both_languages() {
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "pt_BR")] {
            #expect(!L10n.isFlagged(L10n.string(.overlayOptionNeedleGauge, locale: locale)))
            #expect(!L10n.isFlagged(OverlayWidgetOption.maxSpeed.title(locale: locale)))
        }
        #expect(OverlayWidgetOption.maxSpeed.title(locale: Locale(identifier: "en_US"))
            == "Speed dial full scale (km/h)")
    }
}
