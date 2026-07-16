import Foundation

/// Strategy for decoding a ``Session`` from a file URL, reporting progress
/// (issues 2.2 + 2.5).
///
/// Injected into ``SessionStore`` so tests substitute a scripted fake and never
/// invoke the real Rust decode; production is `FFISessionLoader`. `onProgress` is
/// main-actor-isolated and awaited in order, so the store observes progress
/// deterministically.
public protocol SessionLoading: Sendable {
    /// Decode the session at `url`, reporting decode progress, throwing a
    /// ``DecodeError`` (or other error) on failure.
    func load(
        _ url: URL,
        onProgress: @escaping @MainActor (DecodeProgress) -> Void
    ) async throws -> Session
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
    ) async throws -> Session {
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
        return session
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
