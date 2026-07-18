#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Coverage for the production `FFISessionDataSource` adapter (issue 8.1): the
/// 1:1 map from the live `SessionHandle`'s windowed reads into Core's
/// ``DataSample`` / ``ChannelStats`` (timecode ms → seconds; seconds → ms stats
/// window).
///
/// These decode the real `aim_official_test.xrk` through the Rust core and
/// assert the adapter reproduces exactly what the raw FFI accessors return —
/// skipping cleanly when the git-ignored sample is absent (`make fixtures`).
/// Gated on `RaceStudioFFIBindings` so a fresh checkout without the xcframework
/// still builds.
@Suite struct FFISessionDataSourceTests {

    /// The real sample handle, or `nil` (with a skip note) when it is absent.
    private func openReal() throws -> SessionHandle? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return try openSession(path: url.path)
    }

    private func rpmIndex(_ session: SessionHandle) throws -> UInt32 {
        let index = try #require(
            session.channels().firstIndex(where: { $0.name == "RPM" }), "aim sample has an RPM channel")
        return UInt32(index)
    }

    // MARK: - samples: FFI Sample → DataSample (ms → seconds)

    @Test func test_samples_map_ffi_timecodes_to_seconds_and_values() throws {
        guard let session = try openReal() else { return }
        let index = try rpmIndex(session)
        let source = FFISessionDataSource(handle: session)

        let mapped = source.samples(channelIndex: index, start: 0, count: 8)
        let raw = try session.samples(channelIndex: index, start: 0, count: 8)

        try #require(mapped.count == raw.count)
        try #require(!mapped.isEmpty)
        for (got, base) in zip(mapped, raw) {
            #expect(abs(got.time - base.timecode / 1000) < 1e-9, "timecode ms → seconds")
            #expect(got.value == base.value)
        }
    }

    @Test func test_samples_for_out_of_range_channel_index_returns_empty() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        // Past the last channel: the adapter falls back to empty, never a trap.
        let mapped = source.samples(channelIndex: UInt32(session.channels().count), start: 0, count: 4)

        #expect(mapped.isEmpty)
    }

    // MARK: - statistics: FFI StatsDto → ChannelStats (seconds → ms window)

    @Test func test_statistics_map_ffi_stats_over_the_whole_channel() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        let mapped = try source.statistics(channel: "RPM", start: -.infinity, end: .infinity)
        let dto = try session.channelStats(channel: "RPM", window: FfiWindow(start: -.infinity, end: .infinity))

        #expect(mapped.count == dto.count)
        #expect(mapped.min == dto.min)
        #expect(mapped.max == dto.max)
        #expect(mapped.mean == dto.mean)
        #expect(mapped.stdPop == dto.stdPop)
        #expect(mapped.stdSample == dto.stdSample)
        #expect(mapped.rms == dto.rms)
        #expect(mapped.range == dto.range)
    }

    @Test func test_statistics_scale_a_seconds_window_to_the_ffi_millisecond_window() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        // A 0–5 s window (Core seconds) must match the FFI's 0–5000 ms window and
        // report fewer samples than the whole channel.
        let sub = try source.statistics(channel: "RPM", start: 0, end: 5)
        let ffi = try session.channelStats(channel: "RPM", window: FfiWindow(start: 0, end: 5000))
        let whole = try source.statistics(channel: "RPM", start: -.infinity, end: .infinity)

        #expect(sub.count == ffi.count)
        #expect(sub.count < whole.count, "a sub-window has fewer samples")
    }

    @Test func test_statistics_throw_for_an_unknown_channel() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        #expect(throws: (any Error).self) {
            _ = try source.statistics(channel: "NoSuchChannel", start: -.infinity, end: .infinity)
        }
    }
}
#endif
