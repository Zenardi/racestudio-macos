import Foundation
@testable import RaceStudioCore

/// Builds a `Session` from the committed libxrk-derived split goldens
/// (`fixtures/golden/<name>.channels.json` / `.laps.json` / `.metadata.json` /
/// `.gps.json`), so `SessionStore` tests exercise the full load lifecycle
/// against real oracle data **without invoking the Rust decoder**. The
/// production path (`FFISessionLoader`) is covered separately by
/// `FFISessionLoaderTests`.
///
/// The channels golden lists GPS channels alongside the regular ones, but the
/// decoder models GPS separately (`session.channels()` excludes them). This
/// helper applies the same partition the Rust conformance harness uses —
/// regular channels are those with a real sample rate and not owned by the GPS
/// aspect — so the golden-backed fake and the real `FFISessionLoader` agree on
/// the channel count.
enum GoldenSession {

    /// Compose a golden-backed `Session` for the named fixture.
    static func load(_ name: String) throws -> Session {
        let channels: ChannelsGolden = try FixtureLoader.golden(name, aspect: "channels")
        let laps: LapsGolden = try FixtureLoader.golden(name, aspect: "laps")
        let meta: MetadataGolden = try FixtureLoader.golden(name, aspect: "metadata")
        return Session(
            metadata: SessionMetadata(
                vehicle: meta.vehicle, track: meta.track, driver: meta.driver,
                session: meta.session, series: meta.series,
                logDate: meta.logDate, logTime: meta.logTime, datetimeUtc: meta.datetimeUtc),
            channels: regularChannels(channels, gpsNames: gpsChannelNames(name)).map {
                Channel(name: $0.name, unit: $0.units, sampleRateHz: $0.sampleRateHz ?? 0,
                        decimals: UInt8($0.decimals), sampleCount: UInt32($0.samples))
            },
            laps: laps.laps.map {
                Lap(index: UInt32($0.index), startTimeS: $0.startMs / 1000,
                    durationS: $0.durationMs / 1000, endTimeS: $0.endMs / 1000)
            })
    }

    /// The regular (non-GPS) channel count for the named fixture — the count the
    /// decoder's `session.channels()` reports.
    static func channelCount(_ name: String) throws -> Int {
        let channels: ChannelsGolden = try FixtureLoader.golden(name, aspect: "channels")
        return regularChannels(channels, gpsNames: gpsChannelNames(name)).count
    }

    /// The lap count declared by the laps golden (decode oracle).
    static func lapCount(_ name: String) throws -> Int {
        let laps: LapsGolden = try FixtureLoader.golden(name, aspect: "laps")
        return laps.lapCount
    }

    // MARK: - Golden partition (mirrors the Rust harness)

    private static func regularChannels(
        _ golden: ChannelsGolden, gpsNames: Set<String>
    ) -> [ChannelGolden] {
        golden.channels.filter { $0.sampleRateHz != nil && !gpsNames.contains($0.name) }
    }

    private static func gpsChannelNames(_ name: String) -> Set<String> {
        guard let gps: GpsGolden = try? FixtureLoader.golden(name, aspect: "gps") else { return [] }
        return Set(gps.channels.map(\.name))
    }
}

// MARK: - Golden JSON shapes (subset; decoded with `.convertFromSnakeCase`)

private struct ChannelsGolden: Decodable {
    let channels: [ChannelGolden]
}

private struct ChannelGolden: Decodable {
    let name: String
    let units: String
    let sampleRateHz: Double?
    let decimals: Int
    let samples: Int
}

private struct LapsGolden: Decodable {
    let lapCount: Int
    let laps: [LapGolden]
}

private struct LapGolden: Decodable {
    let index: Int
    let startMs: Double
    let durationMs: Double
    let endMs: Double
}

private struct MetadataGolden: Decodable {
    let vehicle, track, driver, session, series, logDate, logTime: String
    let datetimeUtc: Int64
}

private struct GpsGolden: Decodable {
    let channels: [GpsChannelGolden]
}

private struct GpsChannelGolden: Decodable {
    let name: String
}
