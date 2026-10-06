import Foundation

/// The units the video overlay shows its readouts in (issue 9.10).
///
/// A ``TelemetryFrame`` carries canonical metric values (km/h, °C), and every
/// display conversion goes through this one type — the live HUD, the burned-in
/// export and the readouts alike — so they can never disagree on what a mile or
/// a degree Fahrenheit is. The factors themselves are the channel map's
/// (``UnitConversion``), read the other way.
public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    /// km/h and °C — what the frame already holds.
    case metric
    /// mph and °F.
    case imperial

    /// km/h → this system's speed unit.
    public var speedConversion: UnitConversion {
        switch self {
        case .metric: return .identity
        case .imperial: return UnitConversion.milesPerHourToKilometresPerHour.inverse
        }
    }

    /// °C → this system's temperature unit.
    public var temperatureConversion: UnitConversion {
        switch self {
        case .metric: return .identity
        case .imperial: return UnitConversion.fahrenheitToCelsius.inverse
        }
    }

    /// The speed unit's symbol: `km/h` or `mph`.
    public var speedUnit: String {
        switch self {
        case .metric: return "km/h"
        case .imperial: return "mph"
        }
    }

    /// The temperature unit's symbol: `°C` or `°F`.
    public var temperatureUnit: String {
        switch self {
        case .metric: return "°C"
        case .imperial: return "°F"
        }
    }

    /// A frame's speed (km/h) in this system's unit.
    public func speed(fromKilometresPerHour value: Double) -> Double {
        speedConversion.apply(value)
    }

    /// A frame's temperature (°C) in this system's unit.
    public func temperature(fromCelsius value: Double) -> Double {
        temperatureConversion.apply(value)
    }
}
