import Foundation

/// What a channel *means* to the telemetry overlay (issue 9.9): the overlay
/// draws "speed" or "lateral G", not "GPS Speed" or "GPS_LateralAcc", so each
/// session's channels are resolved onto these roles by name and unit
/// (``TelemetryChannelMap``).
public enum TelemetryRole: String, CaseIterable, Codable, Sendable {
    case speed
    case rpm
    case gear
    case throttle
    case brake
    /// Lateral acceleration (g), positive to the right.
    case latG
    /// Longitudinal acceleration (g), positive under acceleration.
    case lonG
    case waterTemp
    case exhaustTemp

    /// The roles in declaration order, stored once — the hot sampling path
    /// iterates this rather than the synthesized ``allCases`` (a fresh array).
    static let ordered: [TelemetryRole] = allCases

    /// This role's position in ``ordered`` — the slot its series and sampling
    /// hint occupy.
    var slot: Int {
        switch self {
        case .speed: return 0
        case .rpm: return 1
        case .gear: return 2
        case .throttle: return 3
        case .brake: return 4
        case .latG: return 5
        case .lonG: return 6
        case .waterTemp: return 7
        case .exhaustTemp: return 8
        }
    }

    /// How the role is read between samples: gear is step-held (a gear is never
    /// "3.5"); every other role is continuous.
    public var interpolation: InterpolationMode {
        self == .gear ? .stepHold : .linear
    }

    /// The unit a frame reports this role in, or `nil` for a role whose value is
    /// passed through in its channel's own unit (gear, pedals — a throttle may be
    /// `%` or `mm`, a brake `bar` or `%`).
    public var canonicalUnit: String? {
        switch self {
        case .speed: return "km/h"
        case .rpm: return "rpm"
        case .latG, .lonG: return "g"
        case .waterTemp, .exhaustTemp: return "°C"
        case .gear, .throttle, .brake: return nil
        }
    }

    /// Channel names that play this role, most preferred first — matched
    /// case- and whitespace-insensitively. Covers the MyChron `.xrk` names (the
    /// decoder's libxrk GPS names), RaceStudio's CSV names, and common names
    /// from other loggers.
    public var candidateNames: [String] {
        switch self {
        case .speed: return ["GPS Speed", "Speed", "Vehicle Speed", "Ground Speed", "Wheel Speed"]
        case .rpm: return ["RPM", "Engine RPM", "Engine Speed", "Eng RPM"]
        case .gear: return ["Gear", "Gear Pos", "Gear Position", "Calculated Gear"]
        case .throttle: return ["Throttle", "TPS", "Throttle Pos", "Throttle Position", "ACCEL", "Pedal Pos"]
        case .brake: return ["Brake", "Brake Pressure", "Brake Press", "BRK", "Brake Pos", "Brake Front"]
        case .latG:
            return ["GPS LatAcc", "GPS_LateralAcc", "LateralAcc", "Lateral Acc", "LatAcc", "Lat G", "Lateral G"]
        case .lonG:
            return ["GPS InlineAcc", "GPS_InlineAcc", "InlineAcc", "Inline Acc", "LongAcc",
                    "Longitudinal Acc", "Lon G", "Long G"]
        case .waterTemp:
            return ["Water Temp", "Water Temperature", "WaterTemp", "WT", "Coolant Temp", "H2O Temp", "Engine Temp"]
        case .exhaustTemp: return ["Exhaust Temp", "Exhaust Temperature", "EGT", "Exh Temp", "EGT 1"]
        }
    }

    /// The conversion from a channel logged in `unit` into ``canonicalUnit``, or
    /// `nil` when this role cannot be in that unit (a "Speed" channel in volts
    /// is not a speed). Pass-through roles accept any unit as identity.
    public func conversion(fromUnit unit: String) -> UnitConversion? {
        let key = unit.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .speed: return Self.speedUnits[key]
        case .rpm: return Self.rpmUnits.contains(key) ? .identity : nil
        case .latG, .lonG: return Self.accelerationUnits[key]
        case .waterTemp, .exhaustTemp: return Self.temperatureUnits[key]
        case .gear, .throttle, .brake: return .identity
        }
    }

    // MARK: - Unit tables (lower-cased keys)

    private static let speedUnits: [String: UnitConversion] = [
        "km/h": .identity, "kmh": .identity, "kph": .identity,
        "m/s": UnitConversion(scale: 3.6), "mps": UnitConversion(scale: 3.6),
        "mph": UnitConversion(scale: 1.609344)
    ]

    private static let rpmUnits: Set<String> = ["rpm", "", "1/min", "rev/min"]

    /// Standard gravity, for m/s² → g.
    private static let standardGravity = 9.80665

    private static let accelerationUnits: [String: UnitConversion] = [
        "g": .identity,
        "m/s²": UnitConversion(scale: 1 / standardGravity),
        "m/s^2": UnitConversion(scale: 1 / standardGravity),
        "m/s2": UnitConversion(scale: 1 / standardGravity)
    ]

    private static let temperatureUnits: [String: UnitConversion] = [
        "c": .identity, "°c": .identity, "degc": .identity, "deg c": .identity, "": .identity,
        "f": .fahrenheitToCelsius, "°f": .fahrenheitToCelsius, "degf": .fahrenheitToCelsius,
        "k": UnitConversion(scale: 1, offset: -273.15)
    ]
}

/// An affine unit conversion, `value · scale + offset` — enough for every
/// role's units (m/s → km/h, m/s² → g, °F → °C).
public struct UnitConversion: Equatable, Sendable {
    public let scale: Double
    public let offset: Double

    public init(scale: Double, offset: Double = 0) {
        self.scale = scale
        self.offset = offset
    }

    /// No conversion: the channel is already in the role's unit.
    public static let identity = UnitConversion(scale: 1)

    /// °F → °C.
    static let fahrenheitToCelsius = UnitConversion(scale: 5.0 / 9.0, offset: -32.0 * 5.0 / 9.0)

    /// `value` in the target unit.
    public func apply(_ value: Double) -> Double {
        value * scale + offset
    }
}
