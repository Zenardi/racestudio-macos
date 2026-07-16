import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Round-trip tests for the UniFFI analysis interface (issue 3.8).
///
/// These open the real `aim_official_test.xrk` sample through the generated
/// Swift bindings, call each windowed analysis accessor — `listLaps`,
/// `deltaTSeries`, `channelStats`, `evalMathChannel`, `fftSpectrum` — and assert
/// the values match the same committed JSON goldens the Rust tests use, proving
/// the analysis engine crosses the FFI boundary faithfully. Error paths (invalid
/// expression, out-of-bounds window) surface as a thrown typed `AnalysisError`,
/// never a trap. The `.xrk` sample is git-ignored (fetched by `make fixtures`);
/// when absent the tests skip cleanly.
@Suite struct AnalysisFFITests {

    /// The whole-session window.
    private func all() -> FfiWindow { FfiWindow(start: -.infinity, end: .infinity) }

    /// The real sample path, or `nil` (with a skip note) when it is absent.
    private func xrkOrSkip() -> String? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url.path
    }

    private func openReal() throws -> SessionHandle? {
        guard let path = xrkOrSkip() else { return nil }
        return try openSession(path: path)
    }

    // MARK: - Golden decodables (snake_case → camelCase via FixtureLoader)

    private struct LapsGolden: Decodable { let laps: [LapGolden] }
    private struct LapGolden: Decodable {
        let index: Int; let startMs: Double; let durationMs: Double
    }
    private struct DeltaGolden: Decodable {
        let referenceIndex: Int; let comparisonIndex: Int; let points: [DeltaPointGolden]
    }
    private struct DeltaPointGolden: Decodable { let distance: Double; let dt: Double }
    private struct StatsGolden: Decodable { let channels: [StatsChannelGolden] }
    private struct StatsChannelGolden: Decodable {
        let name: String; let count: Int; let min: Double; let max: Double
        let mean: Double; let stdPop: Double; let stdSample: Double
        let rms: Double; let range: Double
    }
    private struct FftGolden: Decodable {
        let channel: String; let start: Double; let end: Double
        let window: String; let freqs: [Double]; let amps: [Double]
    }

    /// Linear interpolation of a `(distance, dt)` series at `distance`.
    private func dtAt(_ series: [DeltaPoint], _ distance: Double) -> Double {
        if distance <= series[0].distance { return series[0].dt }
        for i in 1..<series.count where distance <= series[i].distance {
            let (a, b) = (series[i - 1], series[i])
            let span = b.distance - a.distance
            if span == 0 { return a.dt }
            return a.dt + (b.dt - a.dt) * (distance - a.distance) / span
        }
        return series[series.count - 1].dt
    }

    // MARK: - list_laps

    @Test func test_list_laps_ffi_matches_rust() throws {
        guard let session = try openReal() else { return }
        let golden: LapsGolden = try FixtureLoader.golden("aim_official_test", aspect: "laps")

        let laps = try session.listLaps(window: all())
        // `#require` halts the test (throws) so an empty/short result fails
        // cleanly here instead of trapping on a subscript below.
        try #require(laps.count == golden.laps.count, "same lap count")
        for (ffi, want) in zip(laps, golden.laps) {
            #expect(ffi.index == UInt32(want.index))
            #expect(abs(ffi.startTimeS - want.startMs / 1000) < 1e-6)
            #expect(abs(ffi.durationS - want.durationMs / 1000) < 1e-6)
        }

        // A window covering only the first lap returns just it.
        let first = try #require(laps.first)
        let windowed = try session.listLaps(
            window: FfiWindow(start: first.startTimeS, end: first.endTimeS - 0.001))
        try #require(windowed.count == 1)
        #expect(windowed[0].index == 0)
    }

    // MARK: - delta_t

    @Test func test_delta_t_series_windowed_accessor() throws {
        guard let session = try openReal() else { return }
        let golden: DeltaGolden = try FixtureLoader.golden("aim_official_test", aspect: "delta_t")

        let series = try session.deltaTSeries(
            reference: UInt32(golden.referenceIndex),
            comparison: UInt32(golden.comparisonIndex),
            window: all())
        // `#require` halts before the subscripts below, so an empty series is a
        // clean failure rather than an out-of-bounds trap.
        try #require(!series.isEmpty)
        #expect(abs(series[0].dt) < 1e-6, "delta-t starts at 0")
        for point in golden.points {
            #expect(abs(dtAt(series, point.distance) - point.dt) < 1e-3,
                    "delta-t at \(point.distance): \(dtAt(series, point.distance)) vs \(point.dt)")
        }

        // A distance window trims the series to points within it.
        let mid = series[series.count / 2].distance
        let trimmed = try session.deltaTSeries(
            reference: UInt32(golden.referenceIndex),
            comparison: UInt32(golden.comparisonIndex),
            window: FfiWindow(start: 0, end: mid))
        #expect(trimmed.count < series.count)
        #expect(trimmed.allSatisfy { $0.distance <= mid })
    }

    // MARK: - channel_stats

    @Test func test_channel_stats_over_window() throws {
        guard let session = try openReal() else { return }
        let golden: StatsGolden = try FixtureLoader.golden("aim_official_test", aspect: "stats")
        guard let rpm = golden.channels.first(where: { $0.name == "RPM" }) else {
            Issue.record("RPM not in stats golden"); return
        }

        // Whole-channel stats over the unbounded window equal the numpy golden.
        let stats = try session.channelStats(channel: "RPM", window: all())
        #expect(Int(stats.count) == rpm.count)
        #expect(abs(stats.min - rpm.min) < 1e-6)
        #expect(abs(stats.max - rpm.max) < 1e-6)
        #expect(abs(stats.mean - rpm.mean) < 1e-6)
        #expect(abs(stats.stdPop - rpm.stdPop) < 1e-6)
        #expect(abs(stats.rms - rpm.rms) < 1e-6)
        #expect(abs(stats.range - rpm.range) < 1e-6)

        // A sub-window reports fewer samples than the whole channel.
        let sub = try session.channelStats(channel: "RPM", window: FfiWindow(start: 0, end: 5000))
        #expect(Int(sub.count) < rpm.count, "sub-window has fewer samples")
        #expect(sub.max >= sub.min, "a non-empty window yields ordered stats")
    }

    // MARK: - eval_math_channel

    @Test func test_eval_math_channel_ffi() throws {
        guard let session = try openReal() else { return }
        guard let rpmIndex = session.channels().firstIndex(where: { $0.name == "RPM" }) else {
            Issue.record("no RPM channel"); return
        }

        // `2 * RPM + 1` over a window equals 2·value+1 at each RPM timecode.
        let window = FfiWindow(start: 0, end: 5000)
        let evaluated = try session.evalMathChannel(expr: "2 * RPM + 1", window: window)
        let raw = try session.samples(
            channelIndex: UInt32(rpmIndex), start: 0,
            count: session.channels()[rpmIndex].sampleCount)
        let expected = raw.filter { $0.timecode >= window.start && $0.timecode < window.end }
        #expect(evaluated.count == expected.count, "one sample per in-window RPM point")
        for (got, base) in zip(evaluated, expected) {
            #expect(abs(got.timecode - base.timecode) < 1e-6, "timecode preserved")
            #expect(abs(got.value - (2 * base.value + 1)) < 1e-6, "value = 2·RPM+1")
        }
    }

    // MARK: - fft_spectrum

    @Test func test_fft_spectrum_ffi_matches_golden() throws {
        guard let session = try openReal() else { return }
        let golden: FftGolden = try FixtureLoader.golden("aim_official_test", aspect: "fft")

        let spectrum = try session.fftSpectrum(
            channel: golden.channel,
            windowFn: .hann,
            window: FfiWindow(start: golden.start, end: golden.end))

        #expect(spectrum.freqs.count == golden.freqs.count, "bin count")
        for (got, want) in zip(spectrum.freqs, golden.freqs) {
            #expect(abs(got - want) < 1e-6, "freq \(got) vs \(want)")
        }
        for (got, want) in zip(spectrum.amps, golden.amps) {
            #expect(abs(got - want) < 1e-6, "amp \(got) vs \(want)")
        }
    }

    // MARK: - Error paths (thrown typed AnalysisError, never a trap)

    @Test func test_invalid_expr_throws_typed_error() throws {
        guard let session = try openReal() else { return }
        do {
            _ = try session.evalMathChannel(expr: "2 +", window: all())
            Issue.record("invalid expression should throw")
        } catch let error as AnalysisError {
            guard case .InvalidExpression = error else {
                Issue.record("expected InvalidExpression, got \(error)"); return
            }
        }

        // An unknown channel reference is a missing-channel error.
        do {
            _ = try session.evalMathChannel(expr: "Nonexistent * 2", window: all())
            Issue.record("unknown channel should throw")
        } catch let error as AnalysisError {
            guard case .MissingChannel = error else {
                Issue.record("expected MissingChannel, got \(error)"); return
            }
        }
    }

    @Test func test_window_out_of_bounds_throws() throws {
        guard let session = try openReal() else { return }
        let inverted = FfiWindow(start: 5000, end: 1000)
        do {
            _ = try session.channelStats(channel: "RPM", window: inverted)
            Issue.record("inverted window should throw")
        } catch let error as AnalysisError {
            guard case .WindowOutOfBounds = error else {
                Issue.record("expected WindowOutOfBounds, got \(error)"); return
            }
        }

        // A missing channel also throws a typed error, never a trap.
        #expect(throws: AnalysisError.self) {
            _ = try session.channelStats(channel: "NoSuchChannel", window: self.all())
        }
    }
}
