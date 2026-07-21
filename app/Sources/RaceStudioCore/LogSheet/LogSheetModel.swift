import Foundation
import Combine

/// The session/setup Log Sheet (issue 8.17): the user-authored metadata ledger a
/// crew keeps alongside the telemetry — weather, engine, dimensions, weights,
/// fuel, and gearing — plus free-form notes. It persists with the project as a
/// `logSheet` object in the `.rsproj` document (schema v4).
///
/// This is *user-authored* setup metadata, distinct from the decoder-derived,
/// read-only ``SessionMetadata`` on the telemetry ``Session``. Every field carries
/// a sensible default (empty text, `nil` measurement, no ratios), so a brand-new
/// sheet is ``isEmpty`` and the whole value type round-trips through JSON — a
/// `nil` measurement simply omits its key and decodes back to `nil`.
public struct LogSheet: Codable, Equatable, Sendable {

    /// Ambient conditions for the session.
    public struct Weather: Codable, Equatable, Sendable {
        public var airTempC: Double?
        public var trackTempC: Double?
        public var conditions: String
        public var humidityPercent: Double?

        public init(airTempC: Double? = nil, trackTempC: Double? = nil,
                    conditions: String = "", humidityPercent: Double? = nil) {
            self.airTempC = airTempC
            self.trackTempC = trackTempC
            self.conditions = conditions
            self.humidityPercent = humidityPercent
        }
    }

    /// The engine fitted for the session.
    public struct Engine: Codable, Equatable, Sendable {
        public var make: String
        public var displacementCC: Double?
        public var notes: String

        public init(make: String = "", displacementCC: Double? = nil, notes: String = "") {
            self.make = make
            self.displacementCC = displacementCC
            self.notes = notes
        }
    }

    /// Chassis dimensions (millimetres).
    public struct Dimensions: Codable, Equatable, Sendable {
        public var wheelbaseMM: Double?
        public var frontTrackMM: Double?
        public var rearTrackMM: Double?

        public init(wheelbaseMM: Double? = nil, frontTrackMM: Double? = nil, rearTrackMM: Double? = nil) {
            self.wheelbaseMM = wheelbaseMM
            self.frontTrackMM = frontTrackMM
            self.rearTrackMM = rearTrackMM
        }
    }

    /// Corner/axle weights (kilograms).
    public struct Weights: Codable, Equatable, Sendable {
        public var totalKg: Double?
        public var frontKg: Double?
        public var rearKg: Double?

        public init(totalKg: Double? = nil, frontKg: Double? = nil, rearKg: Double? = nil) {
            self.totalKg = totalKg
            self.frontKg = frontKg
            self.rearKg = rearKg
        }
    }

    /// Fuel load and grade.
    public struct Fuel: Codable, Equatable, Sendable {
        public var capacityL: Double?
        public var startLevelL: Double?
        public var type: String

        public init(capacityL: Double? = nil, startLevelL: Double? = nil, type: String = "") {
            self.capacityL = capacityL
            self.startLevelL = startLevelL
            self.type = type
        }
    }

    /// Transmission gearing — final/primary drive and the ordered gear ratios (kept
    /// as text so fractional/entered-as-written values round-trip exactly).
    public struct Gearing: Codable, Equatable, Sendable {
        public var finalDrive: String
        public var primaryDrive: String
        public var ratios: [String]

        public init(finalDrive: String = "", primaryDrive: String = "", ratios: [String] = []) {
            self.finalDrive = finalDrive
            self.primaryDrive = primaryDrive
            self.ratios = ratios
        }
    }

    public var weather: Weather
    public var engine: Engine
    public var dimensions: Dimensions
    public var weights: Weights
    public var fuel: Fuel
    public var gearing: Gearing
    /// Free-form crew notes.
    public var notes: String

    public init(weather: Weather = Weather(), engine: Engine = Engine(),
                dimensions: Dimensions = Dimensions(), weights: Weights = Weights(),
                fuel: Fuel = Fuel(), gearing: Gearing = Gearing(), notes: String = "") {
        self.weather = weather
        self.engine = engine
        self.dimensions = dimensions
        self.weights = weights
        self.fuel = fuel
        self.gearing = gearing
        self.notes = notes
    }

    /// True when nothing has been entered — every field is still at its default.
    public var isEmpty: Bool { self == LogSheet() }
}

/// The editable live home for the ``LogSheet`` (issue 8.17), owned by the analysis
/// window like the 8.8 math-channels manager: the shell's Log Sheet form binds to
/// its ``sheet``, the workspace save captures it into the project via
/// ``AnalysisWindowModel/projectDocument(mathChannels:logSheet:)``, and the
/// workspace open reapplies a loaded document's sheet through ``apply(_:)``.
///
/// `@MainActor` so every published mutation lands on the main actor, matching the
/// other window view-models (the package targets macOS 13, where `@Observable` is
/// unavailable, so this uses `ObservableObject`).
@MainActor
public final class LogSheetModel: ObservableObject {
    /// The current sheet; the Log Sheet form edits it in place.
    @Published public var sheet: LogSheet

    public init(sheet: LogSheet = LogSheet()) {
        self.sheet = sheet
    }

    /// Replace the whole sheet — used to reapply a loaded project's log sheet.
    public func apply(_ sheet: LogSheet) {
        self.sheet = sheet
    }
}
