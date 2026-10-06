import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The readout widgets (issue 9.11): pedals, temperatures, any channel's value,
/// the kart badge and the session info.
@Suite struct ReadoutWidgetTests {

    private let brazilian = OverlayFormatter(locale: Locale(identifier: "pt_BR"))
    private let theme = OverlayTheme.raceStudio

    // MARK: - Pedals

    @Test func test_pedals_with_both_values_write_nothing() {
        let context = OverlayRenderFixture.context(.pedals)

        #expect(PedalsWidget().readouts(OverlayRenderFixture.midLap, context: context).isEmpty)
    }

    @Test func test_a_missing_pedal_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.pedals)

        #expect(PedalsWidget().readouts(TelemetryFrame(time: 0, values: [.throttle: 40]), context: context) == ["—"])
        #expect(PedalsWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—", "—"])
    }

    @Test func test_the_throttle_bar_fills_to_its_percentage() {
        let context = OverlayRenderFixture.context(.pedals, rect: CGRect(x: 0, y: 0, width: 120, height: 200),
                                                   plate: .none)
        let layout = PedalsWidget().layout(in: context)
        let frame = TelemetryFrame(time: 0, values: [.throttle: 72, .brake: 0])

        let bitmap = OverlayRenderFixture.render(PedalsWidget(), frame, context: context)

        let column = CGRect(x: layout.throttle.midX.rounded(.down), y: 0, width: 1, height: 200)
        let filled = bitmap.count(in: column) { $0.matches(self.theme.gain) }
        #expect(abs(filled - Int((layout.throttle.height * 0.72).rounded())) <= 1)
        #expect(bitmap.count(in: layout.brake) { $0.matches(self.theme.loss) } == 0)
    }

    /// A brake logged in bar fills to the widget's brake full scale, not to 100.
    @Test func test_a_pedal_fills_to_its_full_scale() {
        let options = OverlayWidgetOptions(brakeFullScale: 40)
        let context = OverlayRenderFixture.context(.pedals, rect: CGRect(x: 0, y: 0, width: 120, height: 200),
                                                   plate: .none, options: options)
        let layout = PedalsWidget().layout(in: context)
        let frame = TelemetryFrame(time: 0, values: [.throttle: 0, .brake: 25])

        let bitmap = OverlayRenderFixture.render(PedalsWidget(), frame, context: context)

        let column = CGRect(x: layout.brake.midX.rounded(.down), y: 0, width: 1, height: 200)
        let filled = bitmap.count(in: column) { $0.matches(self.theme.loss) }
        #expect(abs(filled - Int((layout.brake.height * 25 / 40).rounded())) <= 1)
    }

    /// A full scale that is not a number — never left by `validated()`, but a
    /// hand-built option can carry one — reads as the default.
    @Test func test_a_pedal_full_scale_that_is_not_a_number_fills_as_a_percentage() {
        let options = OverlayWidgetOptions(brakeFullScale: .nan)
        let context = OverlayRenderFixture.context(.pedals, rect: CGRect(x: 0, y: 0, width: 120, height: 200),
                                                   plate: .none, options: options)
        let layout = PedalsWidget().layout(in: context)

        let bitmap = OverlayRenderFixture.render(PedalsWidget(), TelemetryFrame(time: 0, values: [.brake: 25]),
                                                 context: context)

        let column = CGRect(x: layout.brake.midX.rounded(.down), y: 0, width: 1, height: 200)
        let filled = bitmap.count(in: column) { $0.matches(self.theme.loss) }
        #expect(abs(filled - Int((layout.brake.height * 0.25).rounded())) <= 1)
    }

    @Test func test_pedal_full_scales_default_to_a_percentage() {
        let options = OverlayWidgetOptions()

        #expect(options.throttleFullScale == 100)
        #expect(options.brakeFullScale == 100)
    }

    @Test func test_unusable_pedal_full_scales_are_sanitized() {
        let wild = OverlayWidgetOptions(throttleFullScale: .nan, brakeFullScale: 1e9).validated()
        let tiny = OverlayWidgetOptions(throttleFullScale: 0, brakeFullScale: -3).validated()

        #expect(wild.throttleFullScale == OverlayWidgetOptions.defaultPedalFullScale)
        #expect(wild.brakeFullScale == OverlayWidgetOptions.pedalFullScaleLimits.upperBound)
        #expect(tiny.throttleFullScale == OverlayWidgetOptions.pedalFullScaleLimits.lowerBound)
        #expect(tiny.brakeFullScale == OverlayWidgetOptions.pedalFullScaleLimits.lowerBound)
    }

    @Test func test_pedal_full_scales_persist_and_default_when_missing() throws {
        let options = OverlayWidgetOptions(throttleFullScale: 30, brakeFullScale: 60)

        let decoded = try JSONDecoder().decode(OverlayWidgetOptions.self, from: JSONEncoder().encode(options))
        let older = try JSONDecoder().decode(OverlayWidgetOptions.self, from: Data(#"{"maxRPM": 9000}"#.utf8))

        #expect(decoded == options)
        #expect(older.throttleFullScale == 100)
        #expect(older.brakeFullScale == 100)
    }

    @Test func test_the_pedal_labels_follow_the_export_language() {
        #expect(PedalsWidget.labels(OverlayRenderFixture.context(.pedals)) == ["T", "B"])
        #expect(PedalsWidget.labels(OverlayRenderFixture.context(.pedals, formatter: brazilian)) == ["A", "F"])
    }

    // MARK: - Temperature

    @Test func test_temperatures_read_whole_degrees_with_their_unit() {
        let context = OverlayRenderFixture.context(.temperature)

        #expect(TemperatureWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["54 °C", "612 °C"])
    }

    @Test func test_temperatures_follow_the_widget_units() {
        let context = OverlayRenderFixture.context(.temperature, units: .imperial)

        #expect(TemperatureWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["130 °F", "1134 °F"])
    }

    @Test func test_a_missing_temperature_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.temperature)
        let waterOnly = TelemetryFrame(time: 0, values: [.waterTemp: 55])

        #expect(TemperatureWidget().readouts(waterOnly, context: context) == ["55 °C", "—"])
        #expect(TemperatureWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—", "—"])
    }

    @Test func test_the_temperature_labels_follow_the_export_language() {
        #expect(TemperatureWidget.labels(OverlayRenderFixture.context(.temperature)) == ["H2O", "EGT"])
        #expect(TemperatureWidget.labels(OverlayRenderFixture.context(.temperature, formatter: brazilian))
            == ["ÁGUA", "ESCAPE"])
    }

    // MARK: - Channel value

    @Test(arguments: [
        (TelemetryRole.speed, "87 km/h"), (.rpm, "12850 rpm"), (.gear, "3"), (.throttle, "72 %"),
        (.brake, "0.0 bar"), (.latG, "0.62 g"), (.lonG, "\u{2212}0.35 g"), (.waterTemp, "54 °C"),
        (.exhaustTemp, "612 °C")
    ])
    func test_a_role_readout_writes_the_value_with_its_unit(_ role: TelemetryRole, _ expected: String) {
        let context = OverlayRenderFixture.context(.channelValue(.role(role)))

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: context) == [expected])
    }

    @Test func test_a_role_readout_follows_the_widget_units() {
        let context = OverlayRenderFixture.context(.channelValue(.role(.speed)), units: .imperial)

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["54 mph"])
    }

    @Test func test_a_session_channel_readout_uses_the_channel_precision_and_unit() {
        let context = OverlayRenderFixture.context(.channelValue(.channel("Oil Temp")))

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["98.6 C"])
    }

    @Test func test_a_session_channel_readout_writes_the_export_decimal_mark() {
        let context = OverlayRenderFixture.context(.channelValue(.channel("oil temp")), formatter: brazilian)

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["98,6 C"])
    }

    @Test func test_a_role_without_a_channel_falls_back_to_its_canonical_unit() {
        let unbound = OverlayRenderFixture.session(channels: [])
        let lateral = OverlayRenderFixture.context(.channelValue(.role(.latG)), session: unbound)
        let throttle = OverlayRenderFixture.context(.channelValue(.role(.throttle)), session: unbound)

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: lateral) == ["0.62 g"])
        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: throttle) == ["72"])
    }

    @Test func test_a_channel_the_session_does_not_list_reads_with_two_decimals_and_no_unit() {
        let context = OverlayRenderFixture.context(.channelValue(.channel("Lambda")))
        let frame = TelemetryFrame(time: 0, values: [:], channels: ["Lambda": 0.987])

        #expect(ChannelValueWidget().readouts(frame, context: context) == ["0.99"])
    }

    @Test func test_a_channel_readout_in_a_gap_reads_an_em_dash() {
        let role = OverlayRenderFixture.context(.channelValue(.role(.rpm)))
        let channel = OverlayRenderFixture.context(.channelValue(.channel("Oil Temp")))

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.gap, context: role) == ["—"])
        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.gap, context: channel) == ["—"])
    }

    @Test func test_a_channel_readout_is_labelled_with_its_channel() {
        #expect(ChannelValueWidget.label(OverlayRenderFixture.context(.channelValue(.channel("Oil Temp"))))
            == "OIL TEMP")
        #expect(ChannelValueWidget.label(OverlayRenderFixture.context(.channelValue(.role(.waterTemp)),
                                                                     formatter: brazilian)) == "TEMPERATURA DA ÁGUA")
    }

    // MARK: - Kart badge and session info

    @Test func test_the_kart_badge_shows_the_kart_specification() {
        #expect(KartBadgeWidget.text(OverlayRenderFixture.context(.kartBadge)) == "F4 · Thunder · RBC Honda · 18 HP")
    }

    @Test func test_a_kart_badge_without_a_kart_says_nothing() {
        let context = OverlayRenderFixture.context(.kartBadge, session: OverlayRenderFixture.session(kart: nil))

        #expect(KartBadgeWidget.text(context).isEmpty)
    }

    @Test func test_the_channel_readout_drawer_on_another_kind_of_widget_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.speed)

        #expect(ChannelValueWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["—"])
        #expect(ChannelValueWidget.label(context).isEmpty)
    }

    @Test func test_session_info_joins_venue_date_and_session() {
        #expect(SessionInfoWidget.text(OverlayRenderFixture.context(.sessionInfo))
            == "Synthetic Raceway · 2026-10-06 · Practice 2")
    }

    @Test func test_session_info_skips_what_is_unknown() {
        let metadata = SessionMetadata(vehicle: "", track: " ", driver: "", session: "Race", series: "",
                                       logDate: "someday", logTime: "", datetimeUtc: 0)
        let context = OverlayRenderFixture.context(.sessionInfo,
                                                   session: OverlayRenderFixture.session(metadata: metadata))

        #expect(SessionInfoWidget.text(context) == "someday · Race")
    }

    @Test func test_badge_and_session_info_are_drawn_once_with_the_static_parts() {
        let badge = OverlayRenderFixture.context(.kartBadge)
        let info = OverlayRenderFixture.context(.sessionInfo)

        let badgeStatic = OverlayRenderFixture.render(KartBadgeWidget(), OverlayRenderFixture.midLap, context: badge,
                                                      parts: .staticOnly)
        let badgeDynamic = OverlayRenderFixture.render(KartBadgeWidget(), OverlayRenderFixture.midLap, context: badge,
                                                       parts: .dynamicOnly)
        let infoDynamic = OverlayRenderFixture.render(SessionInfoWidget(), OverlayRenderFixture.midLap, context: info,
                                                      parts: .dynamicOnly)

        #expect(badgeStatic.count { $0.resembles(self.theme.text) } > 50)
        #expect(badgeDynamic.count { !$0.isTransparent } == 0)
        #expect(infoDynamic.count { !$0.isTransparent } == 0)
        #expect(KartBadgeWidget().readouts(OverlayRenderFixture.midLap, context: badge).isEmpty)
        #expect(SessionInfoWidget().readouts(OverlayRenderFixture.midLap, context: info).isEmpty)
    }
}
