import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for widget availability (issue 9.10): checked against what the session
/// can feed — its channels (through the ``TelemetryChannelMap``), laps, sectors,
/// GPS track, kart and details — each widget is available, degraded (drawn with
/// part of its data, saying what is missing) or unavailable (skipped by the
/// renderer, never drawn empty), with a reason the operator can read.
@Suite struct OverlayAvailabilityTests {

    private let en = Locale(identifier: "en")
    private let ptBR = Locale(identifier: "pt-BR")
    private let kart = Kart(id: "k1", name: "Race kart", category: "F4", chassis: "Thunder",
                            engine: "RBC Honda", powerHP: 18)
    private let metadata = SessionMetadata(vehicle: "", track: "Interlagos", driver: "", session: "Treino",
                                           series: "", logDate: "10/04/2026", logTime: "09:12:00", datetimeUtc: 0)

    // MARK: - Fixtures (channel listings only — no samples)

    private func channel(_ name: String, _ unit: String) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: 20, decimals: 2, sampleCount: 1_000)
    }

    /// A MyChron 6 kart session: GPS speed and G, RPM, the logger's delta
    /// channels and its own temperature — no gear, pedals or water temperature.
    private var myChron6: [Channel] {
        [channel("GPS Speed", "km/h"), channel("RPM", "rpm"), channel("GPS LatAcc", "g"),
         channel("GPS InlineAcc", "g"), channel("Best Run Diff", "ms"), channel("Prev Lap Diff", "ms"),
         channel("Logger Temperature", "C"), channel("GPS Latitude", "deg"), channel("GPS Longitude", "deg")]
    }

    /// A GPS-only logger: speed and G from the GPS, nothing from the engine.
    private var gpsOnly: [Channel] {
        [channel("GPS Speed", "km/h"), channel("GPS LatAcc", "g"), channel("GPS InlineAcc", "g")]
    }

    /// A car-style logger with every role.
    private var fullCar: [Channel] {
        gpsOnly + [channel("RPM", "rpm"), channel("Gear", ""), channel("Throttle", "%"), channel("Brake", "bar"),
                   channel("Water Temp", "C"), channel("Exhaust Temp", "C")]
    }

    private func context(_ channels: [Channel], laps: Bool = true, sectors: Bool = true, gps: Bool = true,
                         kart: Kart? = nil, metadata: SessionMetadata? = nil) -> OverlaySessionContext {
        OverlaySessionContext(channelMap: .resolve(channels: channels), hasLaps: laps, hasSectors: sectors,
                              hasTrackPosition: gps, kart: kart, metadata: metadata)
    }

    private func availability(_ kind: OverlayWidgetKind, _ session: OverlaySessionContext) -> WidgetAvailability {
        kind.availability(for: session)
    }

    // MARK: - Whole presets

    /// A session with every channel, a kart and its details feeds every widget of
    /// the fullest preset.
    @Test func test_a_full_session_feeds_every_full_telemetry_widget() {
        let session = context(fullCar, kart: kart, metadata: metadata)

        let result = OverlayPreset.fullTelemetry.layout(locale: en).availability(for: session)

        #expect(result.count == 11)
        #expect(result.values.allSatisfy { $0 == .available })
    }

    /// The real MyChron 6 session feeds the coaching widgets, but has no pedal or
    /// engine temperature channels: those two are reported unavailable, by name.
    @Test func test_a_mychron_session_lacks_only_pedals_and_temperatures() {
        let session = context(myChron6, kart: kart, metadata: metadata)

        let result = OverlayPreset.fullTelemetry.layout(locale: en).availability(for: session)

        #expect(result["pedals"] == .unavailable(.missingRoles(.throttle, .brake)))
        #expect(result["temperature"] == .unavailable(.missingRoles(.waterTemp, .exhaustTemp)))
        #expect(result.filter { $0.value != .available }.count == 2)
        #expect(result["pedals"]?.reason?.label(locale: en) == "No throttle or brake channel")
    }

    /// Availability is keyed by the validated ids, so copied widgets each get one.
    @Test func test_availability_is_keyed_by_unique_widget_ids() {
        let frame = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let layout = OverlayLayout(name: "Twins", widgets: [OverlayWidget(id: "a", kind: .speed, frame: frame),
                                                            OverlayWidget(id: "a", kind: .gear, frame: frame)])

        let result = layout.availability(for: context(myChron6))

        #expect(result == ["a": .available, "a-2": .unavailable(.missingRole(.gear))])
    }

    // MARK: - Channel widgets

    /// A session without an RPM channel has no RPM bar, and says why.
    @Test func test_a_session_without_rpm_has_no_rpm_bar() {
        let result = availability(.rpm, context(gpsOnly))

        #expect(result == .unavailable(.missingRole(.rpm)))
        #expect(result.reason?.label(locale: en) == "No RPM channel")
        #expect(!result.isDrawable)
    }

    /// Speed and gear need their own channels.
    @Test func test_speed_and_gear_need_their_channels() {
        #expect(availability(.speed, context(gpsOnly)) == .available)
        #expect(availability(.speed, context([channel("RPM", "rpm")])) == .unavailable(.missingRole(.speed)))
        #expect(availability(.gear, context(myChron6)) == .unavailable(.missingRole(.gear)))
    }

    /// Brake without throttle draws the brake alone, saying so.
    @Test func test_brake_only_pedals_are_degraded() {
        let result = availability(.pedals, context(gpsOnly + [channel("Brake", "bar")]))

        #expect(result == .degraded(.partialRoles(missing: .throttle, showing: .brake)))
        #expect(result.isDrawable)
        #expect(result.reason?.label(locale: en) == "No throttle channel; showing brake only")
        #expect(result.reason?.label(locale: ptBR) == "Sem canal de acelerador; mostrando apenas freio")
    }

    /// Throttle without brake, and one temperature of two, degrade the same way.
    @Test func test_partial_pedals_and_temperatures_are_degraded() {
        #expect(availability(.pedals, context([channel("Throttle", "%")]))
            == .degraded(.partialRoles(missing: .brake, showing: .throttle)))
        #expect(availability(.temperature, context([channel("Water Temp", "C")]))
            == .degraded(.partialRoles(missing: .exhaustTemp, showing: .waterTemp)))
        #expect(availability(.temperature, context([channel("EGT", "C")]))
            == .degraded(.partialRoles(missing: .waterTemp, showing: .exhaustTemp)))
    }

    /// The G-ball needs both axes for a full ball; one axis draws a line.
    @Test func test_the_g_ball_needs_both_axes() {
        #expect(availability(.gForce, context(gpsOnly)) == .available)
        #expect(availability(.gForce, context([channel("GPS LatAcc", "g")]))
            == .degraded(.partialRoles(missing: .lonG, showing: .latG)))
        #expect(availability(.gForce, context([channel("GPS InlineAcc", "g")]))
            == .degraded(.partialRoles(missing: .latG, showing: .lonG)))
        #expect(availability(.gForce, context([channel("RPM", "rpm")])) == .unavailable(.missingRoles(.latG, .lonG)))
    }

    /// A channel value reads a role or any session channel by name.
    @Test func test_channel_values_need_their_channel() {
        let session = context(myChron6)

        #expect(availability(.channelValue(.role(.rpm)), session) == .available)
        #expect(availability(.channelValue(.role(.waterTemp)), session) == .unavailable(.missingRole(.waterTemp)))
        #expect(availability(.channelValue(.channel(" logger temperature ")), session) == .available)
        #expect(availability(.channelValue(.channel("Oil Temp")), session) == .unavailable(.missingChannel("Oil Temp")))
    }

    /// A channel the session lists but never sampled is no channel.
    @Test func test_an_empty_channel_does_not_count() {
        let empty = Channel(name: "Oil Temp", unit: "C", sampleRateHz: 10, decimals: 1, sampleCount: 0)

        #expect(availability(.channelValue(.channel("Oil Temp")), context([empty]))
            == .unavailable(.missingChannel("Oil Temp")))
    }

    // MARK: - Session widgets

    /// The lap widgets need laps; sector times need sectors too.
    @Test func test_lap_widgets_need_laps_and_sectors() {
        #expect(availability(.lapTimer, context(gpsOnly, laps: false)) == .unavailable(.noLaps))
        #expect(availability(.lapInfo, context(gpsOnly, laps: false)) == .unavailable(.noLaps))
        #expect(availability(.sectorTimes, context(gpsOnly, laps: false)) == .unavailable(.noLaps))
        #expect(availability(.sectorTimes, context(gpsOnly, sectors: false)) == .unavailable(.noSectors))
        #expect(availability(.lapTimer, context(gpsOnly)) == .available)
    }

    /// The map needs the GPS track.
    @Test func test_the_track_map_needs_gps() {
        #expect(availability(.trackMap, context(gpsOnly, gps: false)) == .unavailable(.noTrackPosition))
    }

    /// The delta is computed from laps and GPS distance, or read from the
    /// logger's own delta channel.
    @Test func test_the_delta_needs_a_source() {
        #expect(availability(.delta, context(gpsOnly)) == .available)
        #expect(availability(.delta, context(gpsOnly, laps: false)) == .unavailable(.noLaps))
        #expect(availability(.delta, context(gpsOnly, gps: false)) == .unavailable(.noTrackPosition))
        #expect(availability(.delta, context(myChron6, laps: false, gps: false)) == .available)
    }

    /// The kart badge shows the garage kart's specification; a session without a
    /// kart hides it.
    @Test func test_the_kart_badge_needs_a_kart() {
        let withKart = context(myChron6, kart: kart)

        #expect(availability(.kartBadge, withKart) == .available)
        #expect(withKart.kartBadgeText == "F4 · Thunder · RBC Honda · 18 HP")
        #expect(availability(.kartBadge, context(myChron6)) == .unavailable(.noKart))
        #expect(context(myChron6).kartBadgeText == nil)
    }

    /// A kart with no specification is badged by its name.
    @Test func test_a_kart_without_a_specification_is_badged_by_name() {
        #expect(context(myChron6, kart: Kart(name: "Rental 12")).kartBadgeText == "Rental 12")
    }

    /// Session info shows the venue, date and session — it needs one of them.
    @Test func test_session_info_needs_details() {
        let blank = SessionMetadata(vehicle: " ", track: "", driver: "", session: "", series: "", logDate: "",
                                    logTime: "", datetimeUtc: 0)
        let driverOnly = SessionMetadata(vehicle: "Kart", track: "", driver: "Ana", session: "", series: "F4",
                                         logDate: "", logTime: "", datetimeUtc: 0)
        let dateOnly = SessionMetadata(vehicle: "", track: "", driver: "", session: "", series: "",
                                       logDate: "10/04/2026", logTime: "", datetimeUtc: 0)

        #expect(availability(.sessionInfo, context(myChron6, metadata: metadata)) == .available)
        #expect(availability(.sessionInfo, context(myChron6, metadata: dateOnly)) == .available)
        #expect(availability(.sessionInfo, context(myChron6, metadata: blank)) == .unavailable(.noSessionInfo))
        #expect(availability(.sessionInfo, context(myChron6, metadata: driverOnly)) == .unavailable(.noSessionInfo))
        #expect(availability(.sessionInfo, context(myChron6)) == .unavailable(.noSessionInfo))
    }

    /// What the renderer draws is the draw list without the widgets the session
    /// cannot feed — degraded ones stay.
    @Test func test_the_drawable_list_skips_unavailable_widgets() {
        let session = context(myChron6 + [channel("Brake", "bar")], kart: kart, metadata: metadata)
        let layout = OverlayPreset.fullTelemetry.layout(locale: en)

        let drawn = layout.drawable(for: .standard, session: session)

        #expect(drawn.map(\.id) == layout.resolved(for: .standard).map(\.id).filter { $0 != "temperature" })
        #expect(drawn.contains { $0.id == "pedals" })
    }

    // MARK: - Reasons

    /// Every reason reads as a sentence, in English and Portuguese.
    @Test func test_reasons_read_in_both_languages() {
        let reasons: [OverlayAvailabilityReason] = [
            .missingRole(.latG), .missingRoles(.waterTemp, .exhaustTemp), .partialRoles(missing: .lonG, showing: .latG),
            .missingChannel("Oil Temp"), .noLaps, .noSectors, .noTrackPosition, .noKart, .noSessionInfo
        ]

        #expect(reasons.map { $0.label(locale: en) } == [
            "No lateral G channel", "No water temperature or exhaust temperature channel",
            "No longitudinal G channel; showing lateral G only", "No “Oil Temp” channel in this session",
            "No laps in this session", "No sectors in this session", "No GPS track in this session",
            "No kart assigned to this session", "No session details to show"
        ])
        #expect(reasons.allSatisfy { !L10n.isFlagged($0.label(locale: ptBR)) })
        #expect(OverlayAvailabilityReason.missingRole(.speed).label(locale: ptBR) == "Sem canal de velocidade")
        #expect(OverlayAvailabilityReason.missingRole(.gear).label(locale: en) == "No gear channel")
    }

    /// Only an unavailable widget is skipped; a degraded one is drawn.
    @Test func test_drawable_and_reason() {
        #expect(WidgetAvailability.available.isDrawable)
        #expect(WidgetAvailability.available.reason == nil)
        #expect(WidgetAvailability.degraded(.noKart).isDrawable)
        #expect(WidgetAvailability.degraded(.noKart).reason == .noKart)
        #expect(!WidgetAvailability.unavailable(.noLaps).isDrawable)
    }
}
