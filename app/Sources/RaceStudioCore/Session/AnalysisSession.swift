import Foundation

/// A half-open window of *sample indices* — `[start, start + count)` — used to
/// read a bounded slice of a channel (issue 8.1).
///
/// `AnalysisSession` clamps this against the channel's sample count before any
/// read, so a window that runs past the end never over-reads across the FFI.
/// Mapping a wall-clock time window (or the distance axis) onto an index window
/// is issue 8.2's job; until then callers address samples by index.
public struct SampleWindow: Equatable, Sendable {
    /// Index of the first sample to read.
    public let start: UInt32
    /// Number of samples requested (clamped to what the channel actually has).
    public let count: UInt32

    public init(start: UInt32, count: UInt32) {
        self.start = start
        self.count = count
    }

    /// The whole channel — clamped by ``AnalysisSession`` to the real sample count.
    public static let all = SampleWindow(start: 0, count: .max)
}

/// A time window in **seconds** (session-relative), used to scope channel
/// statistics (issue 8.1). `start` is inclusive, `end` exclusive.
public struct TimeWindow: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// The unbounded window covering the whole session.
    public static let all = TimeWindow(start: -.infinity, end: .infinity)
}

/// One raw channel sample: a logger `time` in **seconds** and its physical
/// `value` (issue 8.1). Core's own mirror of the FFI `Sample`, so the seam and
/// its consumers never depend on the generated bindings.
public struct DataSample: Equatable, Sendable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// One point of the GPS racing line (issue 8.6): a fix's WGS84 position, the
/// cumulative track distance (metres) at it, and its logger time. Core's own
/// mirror of the FFI `GpsTrackPoint`, so the seam and its consumers never depend
/// on the generated bindings; the production adapter converts the FFI timecode
/// (milliseconds) into ``time`` seconds, matching ``DataSample/time``.
public struct GPSTrackPoint: Equatable, Sendable {
    /// The WGS84 latitude/longitude of the fix.
    public let coordinate: GPSCoord
    /// Cumulative track distance (metres) at this fix; `0` when the session has no
    /// distance channel to integrate.
    public let distance: Double
    /// Logger time (seconds, session-relative) of the fix — the same time basis as
    /// the laps and the shared cursor.
    public let time: Double

    public init(coordinate: GPSCoord, distance: Double, time: Double) {
        self.coordinate = coordinate
        self.distance = distance
        self.time = time
    }
}

/// Windowed descriptive statistics for a channel (issue 8.1) — Core's mirror of
/// the FFI `StatsDto`.
public struct ChannelStats: Equatable, Sendable {
    /// Number of finite samples in the window.
    public let count: UInt32
    public let min: Double
    public let max: Double
    public let mean: Double
    /// Population standard deviation (÷ n).
    public let stdPop: Double
    /// Sample standard deviation (÷ n−1; 0 for a single sample).
    public let stdSample: Double
    /// Root mean square.
    public let rms: Double
    /// Peak-to-peak range (`max − min`).
    public let range: Double

    public init(
        count: UInt32, min: Double, max: Double, mean: Double,
        stdPop: Double, stdSample: Double, rms: Double, range: Double
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.mean = mean
        self.stdPop = stdPop
        self.stdSample = stdSample
        self.rms = rms
        self.range = range
    }
}

/// The seam through which ``AnalysisSession`` reads sample data (issue 8.1).
///
/// Production is `FFISessionDataSource`, which retains the live `SessionHandle`
/// and reads windows over the UniFFI boundary; tests substitute a fake that
/// serves canned data, so all of `AnalysisSession`'s logic is covered without
/// the xcframework. Both primitives mirror the FFI's own shape 1:1 so the
/// production adapter stays a trivial, logic-free map.
public protocol SessionDataSource: Sendable {
    /// Read `count` samples of channel `channelIndex` starting at sample index
    /// `start`. Callers (i.e. ``AnalysisSession``) pass an already-clamped window;
    /// implementations must never trap — an out-of-range channel returns `[]`.
    func samples(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DataSample]

    /// Descriptive statistics for the named channel over `[start, end)` seconds.
    /// Throws when the channel is unknown or the window is invalid.
    func statistics(channel: String, start: Double, end: Double) throws -> ChannelStats

    /// Read `count` GPS fixes starting at fix index `start` (issue 8.6), for the
    /// track map's racing line and distance axis. Implementations bound the window
    /// to the real fix count and never trap — a session with no GPS track returns
    /// `[]`.
    func gpsTrack(start: UInt32, count: UInt32) -> [GPSTrackPoint]
}

/// The live analysis pump for a loaded session (issue 8.1) — the linchpin of the
/// M8 workspace.
///
/// Unlike ``Session`` (a value snapshot of metadata/channels/laps), this retains
/// the underlying data source for the session's whole lifetime and vends the
/// windowed value types the M4 views already consume — ``ChannelTrace``,
/// ``ChannelSeries``, ``ChannelStats`` — clamped to each channel's real extent.
/// It is `@MainActor` because it owns the (main-actor) handle's lifetime and the
/// UI reads from it on the main actor; it stays behind the ``SessionDataSource``
/// seam so Core never links the FFI binary.
///
/// Reads are **synchronous on the main actor**, so hot-path callers should pass a
/// bounded `window` (a viewport) rather than ``SampleWindow/all`` for large
/// channels — the windowed FFI read exists precisely so the UI never copies a
/// whole channel to show part of it. Off-main / async reads for full-channel work
/// arrive with the window shell in issue 8.3.
///
/// The distance axis of returned traces is populated in issue 8.2; until then it
/// is a placeholder (`0`) and only the time basis carries data.
@MainActor
public final class AnalysisSession {

    /// The decoded session snapshot this pump serves.
    public let session: Session

    private let dataSource: SessionDataSource

    /// - Parameters:
    ///   - session: the decoded session (metadata/channels/laps).
    ///   - dataSource: the live source windowed reads go through.
    public init(session: Session, dataSource: SessionDataSource) {
        self.session = session
        self.dataSource = dataSource
    }

    /// A ``ChannelTrace`` for the channel at `channelIndex` over `window`, built
    /// from the sample slice clamped to the channel's available range (never
    /// over-reads). An out-of-range channel yields an empty, empty-named trace.
    public func trace(channelIndex: Int, window: SampleWindow = .all) -> ChannelTrace {
        guard let channel = channel(at: channelIndex) else { return ChannelTrace(name: "", samples: []) }
        let raw = read(channelIndex: channelIndex, window: window, sampleCount: channel.sampleCount)
        // Distance is populated in 8.2; only the time basis carries data today.
        let samples = raw.map { PlotSample(time: $0.time, distance: 0, value: $0.value) }
        return ChannelTrace(name: channel.name, samples: samples)
    }

    /// A ``ChannelSeries`` (parallel `xs`/`values` on the time basis) for the
    /// channel at `channelIndex` over `window`, clamped as ``trace(channelIndex:window:)``
    /// is. An out-of-range channel yields an empty series.
    public func series(channelIndex: Int, window: SampleWindow = .all) -> ChannelSeries {
        guard let channel = channel(at: channelIndex) else { return ChannelSeries(xs: [], values: []) }
        let raw = read(channelIndex: channelIndex, window: window, sampleCount: channel.sampleCount)
        return ChannelSeries(xs: raw.map(\.time), values: raw.map(\.value))
    }

    /// Descriptive statistics for the named channel over `window`.
    public func stats(channel: String, window: TimeWindow = .all) throws -> ChannelStats {
        try dataSource.statistics(channel: channel, start: window.start, end: window.end)
    }

    /// The GPS racing-line track over `window` (issue 8.6): each fix's position,
    /// cumulative distance, and time, read through 8.2's `gps_track` accessor. The
    /// default reads the whole track; the data source bounds the window to the real
    /// fix count (the session snapshot carries no fix count to clamp against). A
    /// zero-width window issues no read.
    ///
    /// The fix `time` is treated as the same seconds basis as the laps / cursor so
    /// the map marker can sync to the shared cursor by nearest fix. Precise GPS↔CHS
    /// clock alignment (the two logger clocks can drift) is deferred to a later
    /// issue; until then the marker is nearest-fix accurate on that shared-basis
    /// assumption.
    public func gpsTrack(window: SampleWindow = .all) -> [GPSTrackPoint] {
        let requested = window.count
        guard requested > 0 else { return [] }
        return dataSource.gpsTrack(start: window.start, count: requested)
    }

    // MARK: - Internals

    private func channel(at index: Int) -> Channel? {
        session.channels.indices.contains(index) ? session.channels[index] : nil
    }

    /// Read `window` clamped to `[0, sampleCount]`. A zero-width clamp skips the
    /// seam entirely, so no read is issued past the channel's end.
    private func read(channelIndex: Int, window: SampleWindow, sampleCount: UInt32) -> [DataSample] {
        let start = min(window.start, sampleCount)
        let count = min(window.count, sampleCount - start)
        guard count > 0 else { return [] }
        return dataSource.samples(channelIndex: UInt32(channelIndex), start: start, count: count)
    }
}
