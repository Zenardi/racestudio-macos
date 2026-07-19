import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisSession`'s lap-overlay / delta-t adapter (issue 8.7): the
/// distance-aligned ``OverlayLap`` builder (over 8.2's `samples_with_distance`)
/// and the per-lap-pair `deltaSeries` (over 3.2's `delta_t_series`), covered
/// FFI-free through a `FakeSessionDataSource`.
@MainActor
@Suite struct AnalysisSessionOverlayTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "Speed", unit: "km/h", sampleRateHz: 10, decimals: 1, sampleCount: 11)],
            laps: laps())
    }

    /// Two contiguous laps spanning 0…10 s.
    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
         Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10)]
    }

    /// Speed sampled every second t = 0…10: cumulative distance `10·t` m, value `2·t`.
    private func speedWithDistance() -> [DistanceSample] {
        (0...10).map { DistanceSample(time: Double($0), distance: Double($0) * 10, value: Double($0) * 2) }
    }

    private func makeSession(deltas: [FakeSessionDataSource.DeltaKey: [DeltaSample]] = [:],
                             deltaError: Error? = nil) -> AnalysisSession {
        AnalysisSession(session: session(),
                        dataSource: FakeSessionDataSource(banks: [], distanceBanks: [speedWithDistance()],
                                                          deltas: deltas, deltaError: deltaError))
    }

    // MARK: - overlayLaps

    @Test func test_overlay_laps_are_distance_aligned_per_lap() {
        let overlays = makeSession().overlayLaps(channel: "Speed", laps: laps())
        #expect(overlays.count == 2)
        // Both laps re-base to distance 0, so different-position laps share one axis.
        #expect(overlays[0].distances == [0, 10, 20, 30, 40, 50])
        #expect(overlays[1].distances == [0, 10, 20, 30, 40, 50])
        #expect(overlays[0].channels["Speed"] == [0, 2, 4, 6, 8, 10])
        #expect(overlays[1].channels["Speed"] == [10, 12, 14, 16, 18, 20])
    }

    @Test func test_overlay_lap_re_bases_time_to_lap_start() {
        let overlays = makeSession().overlayLaps(channel: "Speed", laps: laps())
        // Lap 1 spans t = 5…10 but its overlay times are 0-based, so laps align.
        #expect(overlays[1].times == [0, 1, 2, 3, 4, 5])
    }

    @Test func test_overlay_lap_carries_id_and_label() {
        let overlays = makeSession().overlayLaps(channel: "Speed", laps: laps())
        #expect(overlays[0].id == LapID(0))
        #expect(overlays[0].label == "Lap 1")
        #expect(overlays[1].id == LapID(1))
        #expect(overlays[1].label == "Lap 2")
    }

    @Test func test_overlay_laps_for_an_unknown_channel_is_empty() {
        #expect(makeSession().overlayLaps(channel: "Nope", laps: laps()).isEmpty)
    }

    @Test func test_overlay_laps_skips_a_lap_with_no_samples_in_range() {
        // A lap out past the samples (t = 50…55) contributes no overlay row.
        let outLap = Lap(index: 2, startTimeS: 50, durationS: 5, endTimeS: 55)
        let overlays = makeSession().overlayLaps(channel: "Speed", laps: [laps()[0], outLap])
        #expect(overlays.map(\.id) == [LapID(0)])
    }

    // MARK: - deltaSeries

    @Test func test_delta_series_returns_the_pairs_series_over_the_whole_lap() throws {
        let series = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 50, dt: 1.2)]
        let source = FakeSessionDataSource(banks: [], distanceBanks: [speedWithDistance()],
                                           deltas: [.init(reference: 0, comparison: 1): series])
        let sut = AnalysisSession(session: session(), dataSource: source)

        let delta = sut.deltaSeries(reference: laps()[0], comparison: laps()[1])

        #expect(delta == series)
        // The whole-lap distance window is forwarded across the seam.
        #expect(source.lastDeltaRequest
            == FakeSessionDataSource.DeltaRequest(reference: 0, comparison: 1, start: -.infinity, end: .infinity))
    }

    @Test func test_delta_series_for_the_same_lap_is_empty_and_issues_no_read() {
        let source = FakeSessionDataSource(banks: [], distanceBanks: [speedWithDistance()])
        let sut = AnalysisSession(session: session(), dataSource: source)

        #expect(sut.deltaSeries(reference: laps()[0], comparison: laps()[0]).isEmpty)
        #expect(source.lastDeltaRequest == nil, "a lap against itself needs no delta read")
    }

    @Test func test_delta_series_swallows_a_data_source_error() {
        struct Boom: Error {}
        let sut = makeSession(deltaError: Boom())
        #expect(sut.deltaSeries(reference: laps()[0], comparison: laps()[1]).isEmpty)
    }
}
