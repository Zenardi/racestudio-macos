import Foundation

/// Strategy for decoding a ``Session`` from a file URL (issue 2.2).
///
/// Injected into ``SessionStore`` so tests substitute a golden-backed fake and
/// never invoke the real Rust decode; production is `FFISessionLoader`.
public protocol SessionLoading: Sendable {
    /// Decode the session at `url`, throwing on any decode/IO failure.
    func load(_ url: URL) async throws -> Session
}

#if canImport(RaceStudioFFIBindings)
import RaceStudioFFIBindings

/// Production loader: decodes through the Rust core via the 1.7 UniFFI bindings
/// in `app/Generated`, mapping the opaque `SessionHandle` into Core's own
/// ``Session`` value type.
///
/// Available when the `RaceStudioFFI.xcframework` has been built
/// (`scripts/build_xcframework.sh`); a fresh checkout without it builds without
/// this type.
public struct FFISessionLoader: SessionLoading {

    public init() {}

    public func load(_ url: URL) async throws -> Session {
        let handle = try openSession(path: url.path)
        return FFISessionLoader.makeSession(
            metadata: handle.metadata(), channels: handle.channels(), laps: handle.laps())
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

public extension SessionStore {
    /// Production convenience: decode sessions through the Rust core.
    convenience init() {
        self.init(loader: FFISessionLoader())
    }
}
#endif
