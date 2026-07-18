import Foundation

/// A fully decoded telemetry session — the immutable domain model the M2 UI
/// binds to (issue 2.2).
///
/// This is `RaceStudioCore`'s own value type, deliberately independent of the
/// UniFFI wire structs in `app/Generated`: `FFISessionLoader` maps the decoded
/// FFI handle into this model, so the store, view-model, and later screens never
/// depend on the generated bindings' shape. Sample data is read lazily/windowed
/// through the FFI later; this model carries only the session-level summary
/// (metadata + channel/lap listings).
public struct Session: Equatable, Sendable {

    /// Session-level metadata (driver, vehicle, venue, timestamps).
    public let metadata: SessionMetadata

    /// The decoded channels (listing only — no bulk samples).
    public let channels: [Channel]

    /// The decoded laps, in session order.
    public let laps: [Lap]

    public init(metadata: SessionMetadata, channels: [Channel], laps: [Lap]) {
        self.metadata = metadata
        self.channels = channels
        self.laps = laps
    }
}

/// Session-level metadata, mirroring the decoder's `SessionMetadata`.
public struct SessionMetadata: Equatable, Sendable {
    public let vehicle: String
    public let track: String
    public let driver: String
    public let session: String
    public let series: String
    /// Raw log date as stored (`MM/DD/YYYY`).
    public let logDate: String
    /// Raw log time as stored (`HH:MM:SS`).
    public let logTime: String
    /// Session start as epoch seconds (UTC; 0 when absent/unparseable).
    public let datetimeUtc: Int64

    public init(
        vehicle: String, track: String, driver: String, session: String,
        series: String, logDate: String, logTime: String, datetimeUtc: Int64
    ) {
        self.vehicle = vehicle
        self.track = track
        self.driver = driver
        self.session = session
        self.series = series
        self.logDate = logDate
        self.logTime = logTime
        self.datetimeUtc = datetimeUtc
    }
}

/// One decoded channel's summary (name/unit/rate/precision + sample count).
public struct Channel: Equatable, Sendable {
    public let name: String
    /// Physical unit (empty when dimensionless).
    public let unit: String
    /// Native sample rate in hertz (0 when unknown).
    public let sampleRateHz: Double
    /// Display precision (decimal places) hint.
    public let decimals: UInt8
    /// Number of samples (reported without copying them).
    public let sampleCount: UInt32

    public init(name: String, unit: String, sampleRateHz: Double, decimals: UInt8, sampleCount: UInt32) {
        self.name = name
        self.unit = unit
        self.sampleRateHz = sampleRateHz
        self.decimals = decimals
        self.sampleCount = sampleCount
    }
}

/// One decoded lap's timing, in seconds relative to the session start.
public struct Lap: Equatable, Sendable {
    /// Zero-based lap index within the session.
    public let index: UInt32
    /// Session-relative start time in seconds (cumulative).
    public let startTimeS: Double
    /// Lap duration in seconds.
    public let durationS: Double
    /// Session-relative end time in seconds (`start + duration`).
    public let endTimeS: Double

    public init(index: UInt32, startTimeS: Double, durationS: Double, endTimeS: Double) {
        self.index = index
        self.startTimeS = startTimeS
        self.durationS = durationS
        self.endTimeS = endTimeS
    }

    /// Whether the lap's duration is finite and strictly positive. A degenerate
    /// (zero-length) or non-finite lap is invalid: it is excluded from best-lap
    /// selection and greyed in the side panel (issues 2.4 / 8.4). Shared so every
    /// screen agrees on which laps count.
    public var hasValidDuration: Bool {
        durationS.isFinite && durationS > 0
    }
}
