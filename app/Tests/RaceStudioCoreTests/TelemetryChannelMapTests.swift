import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `TelemetryRole` / `TelemetryChannelMap` (issue 9.9): the session's
/// channels are matched to the overlay's *roles* (speed, rpm, gear, G, …) by an
/// ordered candidate-name table plus a unit check, with values converted to one
/// canonical unit per role. A role with no matching channel stays unbound —
/// the frame then reports `nil`, never a fabricated zero.
@Suite struct TelemetryChannelMapTests {

    // MARK: - Fixtures

    private func channel(_ name: String, _ unit: String, rate: Double = 20, count: UInt32 = 100) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: rate, decimals: 2, sampleCount: count)
    }

    /// A MyChron `.xrk` as the decoder lists it: CHS channels, then the GPS
    /// stream's channels under their libxrk names (speed in m/s).
    private func myChronXRK() -> [Channel] {
        [channel("AccelerometerX", "g", rate: 100), channel("RPM", "rpm", rate: 50),
         channel("Logger Temperature", "C", rate: 1), channel("GPS Speed", "m/s"),
         channel("GPS Latitude", "deg"), channel("GPS Longitude", "deg"),
         channel("GPS_InlineAcc", "g"), channel("GPS_LateralAcc", "g"), channel("GPS_Yaw_Rate", "deg/s")]
    }

    /// The same session exported to RaceStudio's CSV and re-imported: 20 Hz, the
    /// CSV's own GPS names, speed already in km/h, plus the logger's delta channels.
    private func myChronCSV() -> [Channel] {
        [channel("GPS Speed", "km/h"), channel("GPS Heading", "deg"), channel("GPS LatAcc", "g"),
         channel("GPS InlineAcc", "g"), channel("Predictive Time", "ms"), channel("Best Run Diff", "ms"),
         channel("Prev Lap Diff", "ms"), channel("RPM", "rpm"), channel("Internal Batt", "V")]
    }

    // MARK: - Resolution

    /// Given a MyChron `.xrk` channel listing, when the map resolves, then speed,
    /// rpm and both G roles bind to the logger's channels, and speed (m/s) is
    /// converted to the canonical km/h.
    @Test func test_mychron_xrk_channels_resolve_with_unit_conversion() throws {
        let map = TelemetryChannelMap.resolve(channels: myChronXRK())

        let speed = try #require(map.binding(for: .speed))
        #expect(speed.channelName == "GPS Speed")
        #expect(speed.channelIndex == 3, "the binding addresses the channel's index in the listing")
        #expect(speed.unit == "km/h")
        #expect(abs(speed.conversion.apply(10) - 36) < 1e-12, "10 m/s is 36 km/h")
        #expect(map.binding(for: .rpm)?.channelName == "RPM")
        #expect(map.binding(for: .latG)?.channelName == "GPS_LateralAcc")
        #expect(map.binding(for: .lonG)?.channelName == "GPS_InlineAcc")
    }

    /// Given the CSV names (`GPS LatAcc`, km/h speed), when the map resolves, then
    /// the same roles bind, and an already-canonical unit converts as identity.
    @Test func test_mychron_csv_channels_resolve() throws {
        let map = TelemetryChannelMap.resolve(channels: myChronCSV())

        let speed = try #require(map.binding(for: .speed))
        #expect(speed.conversion == .identity)
        #expect(map.binding(for: .latG)?.channelName == "GPS LatAcc")
        #expect(map.binding(for: .lonG)?.channelName == "GPS InlineAcc")
    }

    /// Given a logger with no gear, pedal or temperature channel, when the map
    /// resolves, then those roles are unbound — missing, not zero.
    @Test func test_a_missing_role_is_unbound() {
        let map = TelemetryChannelMap.resolve(channels: myChronXRK())

        for role in [TelemetryRole.gear, .throttle, .brake, .waterTemp, .exhaustTemp] {
            #expect(map.binding(for: role) == nil, "\(role) has no channel")
            #expect(!map.isAvailable(role))
        }
        #expect(map.availableRoles == [.speed, .rpm, .latG, .lonG])
    }

    /// Given a GPS-only session, when the map resolves, then it still has speed
    /// and both G roles.
    @Test func test_a_gps_only_session_still_has_speed_and_g() {
        let gpsOnly = [channel("GPS Speed", "m/s"), channel("GPS_InlineAcc", "g"), channel("GPS_LateralAcc", "g")]

        let map = TelemetryChannelMap.resolve(channels: gpsOnly)

        #expect(map.availableRoles == [.speed, .latG, .lonG])
    }

    /// Given other loggers' names, when the map resolves, then each alternative
    /// binds its role, and a G channel logged in m/s² is converted to g.
    @Test func test_alternative_names_resolve() throws {
        let other = [channel("Vehicle Speed", "km/h"), channel("Engine RPM", "rpm"), channel("Gear", ""),
                     channel("Throttle", "%"), channel("Brake Pressure", "bar"),
                     channel("Lateral Acc", "m/s²"), channel("LongAcc", "m/s^2"),
                     channel("Water Temp", "C"), channel("EGT", "°C")]

        let map = TelemetryChannelMap.resolve(channels: other)

        #expect(map.availableRoles == Set(TelemetryRole.allCases))
        let lateral = try #require(map.binding(for: .latG))
        #expect(abs(lateral.conversion.apply(9.80665) - 1) < 1e-12)
        #expect(lateral.unit == "g")
        #expect(map.binding(for: .brake)?.unit == "bar", "a pass-through role keeps its source unit")
    }

    /// Given two candidates present, when the map resolves, then the earlier
    /// entry of the candidate table wins regardless of channel order.
    @Test func test_candidate_order_beats_channel_order() {
        let both = [channel("Speed", "km/h"), channel("GPS Speed", "m/s")]

        #expect(TelemetryChannelMap.resolve(channels: both).binding(for: .speed)?.channelName == "GPS Speed")
    }

    /// Given a channel whose name matches but whose unit cannot be the role, when
    /// the map resolves, then that channel is skipped for the next candidate.
    @Test func test_a_matching_name_with_the_wrong_unit_is_skipped() {
        let mislabelled = [channel("GPS Speed", "m"), channel("Speed", "mph"), channel("RPM", "V")]

        let map = TelemetryChannelMap.resolve(channels: mislabelled)

        #expect(map.binding(for: .speed)?.channelName == "Speed")
        #expect(abs((map.binding(for: .speed)?.conversion.apply(10) ?? 0) - 16.09344) < 1e-9)
        #expect(map.binding(for: .rpm) == nil, "volts are not revolutions")
    }

    /// Names match case- and whitespace-insensitively; an empty channel (no
    /// samples) is never bound.
    @Test func test_names_match_loosely_but_empty_channels_never_bind() {
        let loose = [channel(" gps speed ", "KM/H"), channel("RPM", "rpm", count: 0)]

        let map = TelemetryChannelMap.resolve(channels: loose)

        #expect(map.binding(for: .speed)?.channelName == " gps speed ")
        #expect(map.binding(for: .rpm) == nil)
    }

    // MARK: - Units

    /// Each role's accepted units convert into its canonical unit.
    @Test func test_unit_conversions_land_in_the_canonical_unit() throws {
        let fahrenheit = try #require(TelemetryRole.waterTemp.conversion(fromUnit: "°F"))
        let kelvin = try #require(TelemetryRole.exhaustTemp.conversion(fromUnit: "K"))
        let celsius = try #require(TelemetryRole.waterTemp.conversion(fromUnit: "degC"))

        #expect(abs(fahrenheit.apply(212) - 100) < 1e-9)
        #expect(abs(kelvin.apply(273.15)) < 1e-9)
        #expect(celsius == .identity)
        #expect(TelemetryRole.speed.conversion(fromUnit: "rpm") == nil)
        #expect(TelemetryRole.latG.conversion(fromUnit: "deg/s") == nil)
        #expect(TelemetryRole.speed.canonicalUnit == "km/h")
        #expect(TelemetryRole.gear.canonicalUnit == nil, "gear passes its value through")
    }

    /// Gear is step-held; every other role is continuous.
    @Test func test_only_gear_is_step_held() {
        for role in TelemetryRole.allCases {
            #expect(role.interpolation == (role == .gear ? .stepHold : .linear), "\(role)")
        }
    }

    // MARK: - Overrides

    /// Given a resolved map, when a role is overridden with another channel, then
    /// that role (only) is rebound — with the channel's unit converted when the
    /// role accepts it.
    @Test func test_an_override_rebinds_one_role() throws {
        let channels = myChronXRK() + [channel("Wheel Speed", "m/s")]
        let map = TelemetryChannelMap.resolve(channels: channels)

        let remapped = map.overriding(.speed, with: channels[9])

        let speed = try #require(remapped.binding(for: .speed))
        #expect(speed.channelName == "Wheel Speed")
        #expect(speed.channelIndex == 9)
        #expect(abs(speed.conversion.apply(1) - 3.6) < 1e-12)
        #expect(remapped.binding(for: .rpm) == map.binding(for: .rpm), "other roles are untouched")
    }

    /// Overriding with `nil` unbinds a role; a channel the session does not have
    /// cannot be bound; a unit the role does not recognise passes through as-is.
    @Test func test_override_edge_cases() throws {
        let channels = myChronXRK()
        let map = TelemetryChannelMap.resolve(channels: channels)

        #expect(map.overriding(.rpm, with: nil).binding(for: .rpm) == nil)
        #expect(map.overriding(.rpm, with: channel("Ghost", "rpm")).binding(for: .rpm) == nil)
        let odd = try #require(map.overriding(.gear, with: channels[0]).binding(for: .gear))
        #expect(odd.conversion == .identity)
        let forced = try #require(map.overriding(.speed, with: channels[2]).binding(for: .speed))
        #expect(forced.conversion == .identity, "an unrecognised unit is the user's call: pass through")
        #expect(forced.unit == "C")
    }

    // MARK: - Logger delta channels

    /// The logger's own running-delta channels are listed (in preference order)
    /// so the UI can offer them as an alternative delta source; the predicted
    /// lap time is not a delta and is left out.
    @Test func test_logger_delta_channels_are_listed() {
        #expect(TelemetryChannelMap.resolve(channels: myChronCSV()).loggerDeltaChannels
                == ["Best Run Diff", "Prev Lap Diff"])
        #expect(TelemetryChannelMap.resolve(channels: myChronXRK()).loggerDeltaChannels.isEmpty)
    }
}
