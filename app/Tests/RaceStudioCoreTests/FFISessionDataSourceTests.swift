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

    // MARK: - detectTrack: FFI DetectedTrack → Core DetectedTrackInfo (issue 9.2)

    @Test func test_detect_track_maps_the_matched_adria_geometry() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        // The Adria fixture matches the bundled `adria` track; the adapter maps its
        // id, name, tolerance, and start/finish + sector gate geometry 1:1.
        let detected = try #require(source.detectTrack(), "Adria is recognized")
        let raw = try #require(session.detectTrack())
        #expect(detected.id == raw.id)
        #expect(detected.name == raw.name)
        #expect(detected.toleranceM == raw.toleranceM)
        #expect(detected.sectorGates.count == raw.sectorGates.count)
        #expect(detected.startFinish.start.latitude == raw.startFinish.aLatitude)
        #expect(detected.startFinish.end.longitude == raw.startFinish.bLongitude)
        // The resolved split source is auto-detected, not the beacon fallback.
        #expect(TrackDetectionModel(detected: detected).isAutoDetected)
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

    // MARK: - gpsTrack: FFI GpsTrackPoint → GPSTrackPoint (timecode ms → seconds)

    @Test func test_gps_track_maps_ffi_fixes_to_core_track_points() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        let mapped = source.gpsTrack(start: 0, count: 8)
        let raw = session.gpsTrack(start: 0, count: 8)

        try #require(mapped.count == raw.count)
        try #require(!mapped.isEmpty)
        for (got, base) in zip(mapped, raw) {
            #expect(got.coordinate.latitude == base.latitude)
            #expect(got.coordinate.longitude == base.longitude)
            #expect(got.distance == base.distance)
            #expect(abs(got.time - base.timecode / 1000) < 1e-9, "timecode ms → seconds")
        }
    }

    // MARK: - samplesWithDistance: FFI DistanceSample → DistanceSample (ms → seconds)

    @Test func test_samples_with_distance_maps_ffi_triples_to_seconds() throws {
        guard let session = try openReal() else { return }
        let index = try rpmIndex(session)
        let source = FFISessionDataSource(handle: session)

        let mapped = source.samplesWithDistance(channelIndex: index, start: 0, count: 8)
        let raw = try session.samplesWithDistance(channelIndex: index, start: 0, count: 8)

        try #require(mapped.count == raw.count)
        try #require(!mapped.isEmpty)
        for (got, base) in zip(mapped, raw) {
            #expect(abs(got.time - base.timecode / 1000) < 1e-9, "timecode ms → seconds")
            #expect(got.distance == base.distance)
            #expect(got.value == base.value)
        }
    }

    // MARK: - deltaT: FFI DeltaPoint → DeltaSample over a distance window

    @Test func test_delta_t_maps_ffi_points_over_the_whole_lap() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)
        let laps = session.laps()
        try #require(laps.count >= 2, "aim sample has ≥ 2 laps")

        let mapped = try source.deltaT(referenceLap: laps[0].index, comparisonLap: laps[1].index,
                                       start: -.infinity, end: .infinity)
        let raw = try session.deltaTSeries(reference: laps[0].index, comparison: laps[1].index,
                                           window: FfiWindow(start: -.infinity, end: .infinity))

        try #require(mapped.count == raw.count)
        try #require(!mapped.isEmpty)
        for (got, base) in zip(mapped, raw) {
            #expect(got.distance == base.distance)
            #expect(got.dt == base.dt)
        }
    }

    // MARK: - segmentTimes: FFI LapSegmentTimes → LapSegments (issue 8.11)

    @Test func test_segment_times_maps_ffi_rows_to_core_lap_segments() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        let mapped = source.segmentTimes(splits: 5)
        let raw = session.segmentTimes(splits: 5)

        try #require(mapped.count == raw.count)
        try #require(!mapped.isEmpty)
        for (got, base) in zip(mapped, raw) {
            #expect(got.lap.index == Int(base.lapIndex), "lap index crosses the seam")
            #expect(got.baseTimes == base.segmentTimes, "the segment times map 1:1 (already seconds)")
        }
    }

    // MARK: - spectrum: FFI SpectrumDto → ChannelSpectrum (seconds → ms window) (issue 8.16)

    @Test func test_spectrum_maps_ffi_dto_over_the_whole_channel() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        let mapped = try source.spectrum(channel: "RPM", windowFunction: .hann, start: -.infinity, end: .infinity)
        let dto = try session.fftSpectrum(
            channel: "RPM", windowFn: .hann, window: FfiWindow(start: -.infinity, end: .infinity))

        #expect(mapped.freqs == dto.freqs, "the frequency axis maps 1:1")
        #expect(mapped.amps == dto.amps, "the amplitudes map 1:1")
        #expect(!mapped.freqs.isEmpty, "a real channel transforms — the engine resampled it first")
    }

    @Test func test_spectrum_scales_a_seconds_window_to_the_ffi_millisecond_window() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        // A 0–5 s window (Core seconds) must match the FFI's 0–5000 ms window.
        let sub = try source.spectrum(channel: "RPM", windowFunction: .hann, start: 0, end: 5)
        let ffi = try session.fftSpectrum(
            channel: "RPM", windowFn: .hann, window: FfiWindow(start: 0, end: 5000))

        #expect(sub.freqs == ffi.freqs)
        #expect(sub.amps == ffi.amps)
    }

    @Test func test_spectrum_maps_each_core_window_function_to_its_ffi_taper() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)
        let pairs: [(SpectrumWindowKind, SpectrumWindow)] = [
            (.rectangular, .rectangular), (.hann, .hann), (.hamming, .hamming), (.blackman, .blackman)
        ]

        for (core, ffi) in pairs {
            let mapped = try source.spectrum(channel: "RPM", windowFunction: core, start: -.infinity, end: .infinity)
            let dto = try session.fftSpectrum(
                channel: "RPM", windowFn: ffi, window: FfiWindow(start: -.infinity, end: .infinity))
            #expect(mapped.amps == dto.amps, "\(core) maps to the \(ffi) taper")
        }
    }

    @Test func test_spectrum_throws_for_an_unknown_channel() throws {
        guard let session = try openReal() else { return }
        let source = FFISessionDataSource(handle: session)

        #expect(throws: (any Error).self) {
            _ = try source.spectrum(channel: "NoSuchChannel", windowFunction: .hann, start: -.infinity, end: .infinity)
        }
    }
}
#endif
