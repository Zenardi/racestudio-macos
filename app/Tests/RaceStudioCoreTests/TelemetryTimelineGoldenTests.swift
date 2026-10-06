import Testing
import Foundation

@testable import RaceStudioCore

/// Oracle conformance for `TelemetryTimeline` (issue 9.9): on the public MyChron
/// sample `aim_official_test.xrk`, decoded and served by the real FFI, the frame
/// at 12 chosen instants carries the speed, rpm, lateral/longitudinal G, track
/// position, lap number, lap time, last/best lap and live delta that the libxrk oracle
/// computes independently (`scripts/gen_telemetry_golden.py`, committed as
/// `fixtures/golden/aim_official_test.telemetry.json`), within the tolerances in
/// `docs/DECODE_TOLERANCES.md` ("Telemetry frames").
///
/// Instants are `(lap, seconds past its beacon)`, re-anchored here on the
/// decoder's own lap starts. The `.xrk` is git-ignored (fetched by
/// `make fixtures`, and by CI); without it the test skips cleanly. Excluded from
/// the build when the xcframework is absent (`testExcludes` in `Package.swift`).
@Suite struct TelemetryTimelineGoldenTests {

    // MARK: - Tolerances (docs/DECODE_TOLERANCES.md, "Telemetry frames")

    /// The golden stores speed, G and delta to 6 decimals: half that quantum
    /// plus floating-point noise.
    private static let speedKmh = 1e-6
    private static let gForce = 1e-6
    private static let delta = 1e-6
    /// RPM is stored to 3 decimals.
    private static let rpm = 1e-3
    /// Lap times are millisecond-precise beacon markers.
    private static let seconds = 1e-3
    /// Latitude/longitude are stored to 9 decimals; the decoders agree to the
    /// 8-decimal GPS golden (~1 mm).
    private static let degrees = 1e-8

    // MARK: - Golden

    private struct Golden: Decodable {
        let bestLap: LapGolden
        let lapCount: Int
        let frames: [FrameGolden]
    }

    private struct LapGolden: Decodable {
        let index: Int
        let number: Int
        let timeS: Double
    }

    private struct FrameGolden: Decodable {
        let lapIndex: Int
        let offsetS: Double
        let lapNumber: Int
        let elapsedS: Double
        let isOutLap: Bool
        let isInLap: Bool
        let lastLap: LapGolden?
        let bestSoFar: LapGolden?
        let speedKmh: Double
        let rpm: Double
        let latG: Double
        let lonG: Double
        let latitude: Double
        let longitude: Double
        let deltaS: Double
    }

    private func xrkOrSkip() -> URL? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url
    }

    // MARK: - Conformance

    /// Given the real sample, when its timeline is loaded through the FFI and
    /// sampled at the oracle's instants, then every frame matches the oracle.
    @Test func test_frames_match_the_libxrk_oracle() async throws {
        guard let url = xrkOrSkip() else { return }
        let loaded = try await FFISessionLoader().load(url) { _ in }
        let source = try #require(loaded.dataSource)
        let golden: Golden = try FixtureLoader.golden("aim_official_test", aspect: "telemetry")
        let laps = loaded.session.laps
        try #require(laps.count == golden.lapCount, "same beacon lap table")

        let timeline = try await TelemetryTimeline.load(session: loaded.session, source: source)

        #expect(timeline.clock.best?.lap == LapID(golden.bestLap.index))
        #expect(abs((timeline.clock.best?.time ?? 0) - golden.bestLap.timeS) <= Self.seconds)
        var cursor = SamplingCursor()
        for expected in golden.frames {
            let t = laps[expected.lapIndex].startTimeS + expected.offsetS
            let frame = timeline.frame(at: t)
            #expect(timeline.frame(at: t, cursor: &cursor) == frame, "the sequential path agrees")
            check(frame, against: expected, projection: timeline.position.projection)
        }
    }

    private func check(_ frame: TelemetryFrame, against expected: FrameGolden, projection: GeoProjection) {
        let label = "lap \(expected.lapIndex) + \(expected.offsetS) s"
        let place = frame.position.map { projection.unproject($0.point) }
        #expect(close(place?.latitude, expected.latitude, Self.degrees), "latitude \(label)")
        #expect(close(place?.longitude, expected.longitude, Self.degrees), "longitude \(label)")
        #expect(close(frame.speed, expected.speedKmh, Self.speedKmh), "speed \(label)")
        #expect(close(frame.rpm, expected.rpm, Self.rpm), "rpm \(label)")
        #expect(close(frame.latG, expected.latG, Self.gForce), "latG \(label)")
        #expect(close(frame.lonG, expected.lonG, Self.gForce), "lonG \(label)")
        #expect(close(frame.delta, expected.deltaS, Self.delta), "delta \(label)")
        #expect(frame.lap?.number == expected.lapNumber, "lap number \(label)")
        #expect(close(frame.lap?.elapsed, expected.elapsedS, Self.seconds), "elapsed \(label)")
        #expect(frame.lap?.isOutLap == expected.isOutLap, "out-lap \(label)")
        #expect(frame.lap?.isInLap == expected.isInLap, "in-lap \(label)")
        #expect(same(frame.lap?.last, expected.lastLap), "last lap \(label)")
        #expect(same(frame.lap?.bestSoFar, expected.bestSoFar), "best so far \(label)")
    }

    private func close(_ actual: Double?, _ expected: Double, _ tolerance: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) <= tolerance
    }

    private func same(_ actual: LapTiming?, _ expected: LapGolden?) -> Bool {
        guard let actual, let expected else { return actual == nil && expected == nil }
        return actual.lap == LapID(expected.index) && actual.number == expected.number
            && abs(actual.time - expected.timeS) <= Self.seconds
    }
}
