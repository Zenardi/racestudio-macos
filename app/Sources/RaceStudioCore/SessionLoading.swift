import Foundation

/// The product of a successful load (issue 8.1): the decoded ``Session`` value
/// snapshot plus the live ``SessionDataSource`` that retains the underlying
/// handle for windowed sample reads.
///
/// `dataSource` is optional so loaders that only model the load lifecycle (the
/// counting/cancellation test fakes) need not vend one — the store then leaves
/// ``SessionViewModel/analysis`` `nil`. The production `FFISessionLoader` always
/// provides it, so a real `.loaded` session can pump samples to the analysis UI.
public struct LoadedSession: Sendable {
    /// The decoded metadata/channels/laps snapshot.
    public let session: Session
    /// The live source for windowed reads, or `nil` when the loader models none.
    public let dataSource: SessionDataSource?
    /// The math-channel evaluator built over the retained handle (issue 8.8), so
    /// the Math Channels editor can validate/preview expressions against the live
    /// session. `nil` when the loader vends none (the non-FFI test loaders).
    public let evaluator: (any ExpressionEvaluating)?

    public init(session: Session, dataSource: SessionDataSource? = nil,
                evaluator: (any ExpressionEvaluating)? = nil) {
        self.session = session
        self.dataSource = dataSource
        self.evaluator = evaluator
    }
}

/// Strategy for decoding a ``Session`` from a file URL, reporting progress
/// (issues 2.2 + 2.5).
///
/// Injected into ``SessionStore`` so tests substitute a scripted fake and never
/// invoke the real Rust decode; production is `FFISessionLoader`. `onProgress` is
/// main-actor-isolated and awaited in order, so the store observes progress
/// deterministically.
public protocol SessionLoading: Sendable {
    /// Decode the session at `url`, reporting decode progress, throwing a
    /// ``DecodeError`` (or other error) on failure. Returns the decoded snapshot
    /// plus a live ``SessionDataSource`` (issue 8.1) so the loaded session can
    /// feed the analysis UI without re-decoding.
    func load(
        _ url: URL,
        onProgress: @escaping @MainActor (DecodeProgress) -> Void
    ) async throws -> LoadedSession
}

#if canImport(RaceStudioFFIBindings)
import RaceStudioFFIBindings

/// Production loader: decodes through the Rust core via the 1.7 UniFFI bindings
/// in `app/Generated`, mapping the opaque `SessionHandle` into Core's own
/// ``Session`` value type and translating `FfiDecodeError` into ``DecodeError``.
///
/// Available when the `RaceStudioFFI.xcframework` has been built
/// (`scripts/build_xcframework.sh`); a fresh checkout without it builds without
/// this type.
public struct FFISessionLoader: SessionLoading {

    public init() {}

    public func load(
        _ url: URL,
        onProgress: @escaping @MainActor (DecodeProgress) -> Void
    ) async throws -> LoadedSession {
        await onProgress(DecodeProgress(fraction: 0, phase: .reading))
        let handle: SessionHandle
        do {
            handle = try openSession(path: url.path)
        } catch let error as FfiDecodeError {
            throw DecodeError(error)
        }
        await onProgress(DecodeProgress(fraction: 0.5, phase: .decoding))
        let session = FFISessionLoader.makeSession(
            metadata: handle.metadata(), channels: handle.channels(), laps: handle.laps())
        await onProgress(DecodeProgress(fraction: 1, phase: .complete))
        // Retain the live handle behind the data-source seam so the loaded
        // session can read sample windows for the analysis UI (issue 8.1), and back
        // the Math Channels editor with an evaluator over the same handle (8.8).
        return LoadedSession(session: session, dataSource: FFISessionDataSource(handle: handle),
                             evaluator: FFIExpressionEvaluator(session: handle))
    }

    /// Pure map from the FFI handle's readouts into Core's ``Session``. Split out
    /// from `load` so it is unit-tested directly (no `.xrk` fixture needed);
    /// `load` then only owns the fixture-dependent `openSession` call.
    static func makeSession(
        metadata: RaceStudioFFIBindings.SessionMetadata,
        channels: [ChannelInfo],
        laps: [LapInfo]
    ) -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: metadata.vehicle, track: metadata.track, driver: metadata.driver,
                session: metadata.session, series: metadata.series,
                logDate: metadata.logDate, logTime: metadata.logTime, datetimeUtc: metadata.datetimeUtc),
            channels: channels.map {
                Channel(name: $0.name, unit: $0.unit, sampleRateHz: $0.sampleRateHz,
                        decimals: $0.decimals, sampleCount: $0.sampleCount)
            },
            laps: laps.map {
                Lap(index: $0.index, startTimeS: $0.startTimeS,
                    durationS: $0.durationS, endTimeS: $0.endTimeS)
            })
    }
}

/// Production ``SessionDataSource``: reads windowed samples and stats from a live
/// `SessionHandle` over the 3.8 UniFFI boundary (issue 8.1), mapping each FFI
/// `Sample` into a ``DataSample`` (timecode ms → seconds) and `StatsDto` into a
/// ``ChannelStats``.
///
/// A logic-free 1:1 adapter: `AnalysisSession` owns all windowing/clamping, so
/// this only translates types and units. Available only when the xcframework has
/// been built; a fresh checkout without it compiles without this type.
/// `@unchecked Sendable` because the opaque handle is immutable here and the Rust
/// accessors are thread-safe (matching `FFIExpressionEvaluator`).
public struct FFISessionDataSource: SessionDataSource, @unchecked Sendable {
    private let handle: SessionHandle

    public init(handle: SessionHandle) {
        self.handle = handle
    }

    public func samples(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DataSample] {
        // The window is pre-clamped by `AnalysisSession`; the only throw here is
        // `ChannelOutOfRange` for a bad index, which that guard already excludes —
        // fall back to empty rather than trap (no `try!` in shipped paths).
        let raw = (try? handle.samples(channelIndex: channelIndex, start: start, count: count)) ?? []
        // `timecode` is milliseconds; `DataSample.time` is seconds, matching the
        // app's lap/plot time convention (as `FFIExpressionEvaluator` does).
        return raw.map { DataSample(time: $0.timecode / 1000, value: $0.value) }
    }

    public func statistics(channel: String, start: Double, end: Double) throws -> ChannelStats {
        // The FFI stats window is in the same timecode unit as samples (ms);
        // Core speaks seconds, so scale the bounds (±∞ is preserved).
        let dto = try handle.channelStats(
            channel: channel, window: FfiWindow(start: start * 1000, end: end * 1000))
        return ChannelStats(
            count: dto.count, min: dto.min, max: dto.max, mean: dto.mean,
            stdPop: dto.stdPop, stdSample: dto.stdSample, rms: dto.rms, range: dto.range)
    }

    public func gpsTrack(start: UInt32, count: UInt32) -> [GPSTrackPoint] {
        // 8.2's `gps_track` bounds the window to the real fix count itself, so the
        // adapter only maps each FFI row into Core's ``GPSTrackPoint`` — timecode
        // ms → seconds, as `samples` does, so the track shares the cursor's basis.
        handle.gpsTrack(start: start, count: count).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: $0.latitude, longitude: $0.longitude),
                          distance: $0.distance, time: $0.timecode / 1000)
        }
    }

    public func samplesWithDistance(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DistanceSample] {
        // Pre-clamped by `AnalysisSession`; the only throw is `ChannelOutOfRange`
        // for a bad index, already excluded — fall back to empty rather than trap.
        let raw = (try? handle.samplesWithDistance(channelIndex: channelIndex, start: start, count: count)) ?? []
        // `timecode` is milliseconds; Core's `time` is seconds, as `samples` maps.
        return raw.map { DistanceSample(time: $0.timecode / 1000, distance: $0.distance, value: $0.value) }
    }

    public func deltaT(referenceLap: UInt32, comparisonLap: UInt32,
                       start: Double, end: Double) throws -> [DeltaSample] {
        // The delta-t window is a distance window (metres), not time — pass it
        // through unscaled (`±∞` preserved), mapping each FFI point 1:1.
        let raw = try handle.deltaTSeries(
            reference: referenceLap, comparison: comparisonLap, window: FfiWindow(start: start, end: end))
        return raw.map { DeltaSample(distance: $0.distance, dt: $0.dt) }
    }
}

extension DecodeError {
    /// Translate the FFI's `FfiDecodeError` into Core's ``DecodeError``.
    init(_ ffi: FfiDecodeError) {
        switch ffi {
        case let .Io(message): self = .io(message: message)
        case .BadMagic: self = .badMagic
        case .TruncatedHeader: self = .truncatedHeader
        case .TruncatedChannel: self = .truncatedChannel
        case .BadSampleCount: self = .badSampleCount
        case .TruncatedGps: self = .truncatedGps
        case .TruncatedLaps: self = .truncatedLaps
        case let .ChannelOutOfRange(index, channelCount):
            self = .channelOutOfRange(index: index, channelCount: channelCount)
        case let .Other(message): self = .other(message: message)
        }
    }
}

public extension SessionStore {
    /// Production convenience: decode sessions through the Rust core.
    convenience init() {
        self.init(loader: FFISessionLoader())
    }
}
#endif
