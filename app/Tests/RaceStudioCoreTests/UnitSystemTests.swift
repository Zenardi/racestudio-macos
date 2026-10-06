import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``UnitSystem`` (issue 9.10): the overlay's readouts arrive in the
/// frame's canonical metric units (km/h, °C) and are converted for display in
/// exactly one place, so the live HUD and the burned-in export can never
/// disagree on what a mile or a degree Fahrenheit is.
@Suite struct UnitSystemTests {

    // MARK: - Speed

    /// Metric shows km/h as-is.
    @Test func test_metric_speed_is_kilometres_per_hour() {
        #expect(UnitSystem.metric.speed(fromKilometresPerHour: 112.5) == 112.5)
        #expect(UnitSystem.metric.speedUnit == "km/h")
    }

    /// Imperial converts km/h to mph through the international mile.
    @Test func test_imperial_speed_is_miles_per_hour() {
        let mph = UnitSystem.imperial.speed(fromKilometresPerHour: 160.9344)

        #expect(abs(mph - 100) < 1e-9)
        #expect(UnitSystem.imperial.speedUnit == "mph")
    }

    /// The overlay's mph and the channel map's mph are one definition: a value
    /// logged in mph, read into km/h by the map, shows as the same mph.
    @Test func test_imperial_speed_inverts_the_channel_maps_mph_conversion() throws {
        let toKmh = try #require(TelemetryRole.speed.conversion(fromUnit: "mph"))

        let shown = UnitSystem.imperial.speed(fromKilometresPerHour: toKmh.apply(63.4))

        #expect(abs(shown - 63.4) < 1e-9)
    }

    // MARK: - Temperature

    /// Metric shows °C as-is.
    @Test func test_metric_temperature_is_celsius() {
        #expect(UnitSystem.metric.temperature(fromCelsius: 48) == 48)
        #expect(UnitSystem.metric.temperatureUnit == "°C")
    }

    /// Imperial converts °C to °F (water boils at 212 °F, freezes at 32 °F, and
    /// the scales cross at −40).
    @Test(arguments: [(100.0, 212.0), (0.0, 32.0), (-40.0, -40.0)])
    func test_imperial_temperature_is_fahrenheit(celsius: Double, fahrenheit: Double) {
        #expect(abs(UnitSystem.imperial.temperature(fromCelsius: celsius) - fahrenheit) < 1e-9)
        #expect(UnitSystem.imperial.temperatureUnit == "°F")
    }

    // MARK: - The shared conversion

    /// A conversion's inverse undoes it — scale and offset alike.
    @Test func test_unit_conversion_inverse_undoes_the_conversion() {
        let celsiusToKelvinish = UnitConversion(scale: 1.8, offset: 32)

        let roundTrip = celsiusToKelvinish.inverse.apply(celsiusToKelvinish.apply(21.5))

        #expect(abs(roundTrip - 21.5) < 1e-12)
    }

    /// The units persist by name, so a saved layout reads back the same system.
    @Test func test_unit_system_persists_by_name() throws {
        let data = try JSONEncoder().encode([UnitSystem.imperial])

        #expect(String(bytes: data, encoding: .utf8) == #"["imperial"]"#)
    }
}
