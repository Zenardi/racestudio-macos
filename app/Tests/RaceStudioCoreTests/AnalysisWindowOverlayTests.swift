import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisWindowModel`'s lap-overlay panel (issue 8.7): the
/// distance-aligned overlay laps, the per-pair delta-t series keyed to the shared
/// reference lap, and the overlay channel — all rebuilt from the shared selection.
/// Covered FFI-free through a `FakeSessionDataSource`.
@MainActor
@Suite struct AnalysisWindowOverlayTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "Speed", unit: "km/h", sampleRateHz: 10, decimals: 1, sampleCount: 11),
                       Channel(name: "RPM", unit: "rpm", sampleRateHz: 10, decimals: 0, sampleCount: 11)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
                   Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10)])
    }

    /// Distance-paired samples at t = 0…10: cumulative distance `10·t`, value `scale·t`.
    private func withDistance(scale: Double) -> [DistanceSample] {
        (0...10).map { DistanceSample(time: Double($0), distance: Double($0) * 10, value: Double($0) * scale) }
    }

    private func deltas() -> [FakeSessionDataSource.DeltaKey: [DeltaSample]] {
        [.init(reference: 0, comparison: 1): [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 50, dt: 1.2)],
         .init(reference: 1, comparison: 0): [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 50, dt: -1.2)]]
    }

    private func makeModel(analysisPresent: Bool = true) -> AnalysisWindowModel {
        let sess = session()
        let analysis: AnalysisSession? = analysisPresent
            ? AnalysisSession(session: sess,
                              dataSource: FakeSessionDataSource(
                                banks: [], distanceBanks: [withDistance(scale: 2), withDistance(scale: 100)],
                                deltas: deltas()))
            : nil
        return AnalysisWindowModel(session: sess, analysis: analysis)
    }

    /// A model with both laps selected (reference = lap 0).
    private func overlaidModel() -> AnalysisWindowModel {
        let model = makeModel()
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(1))
        return model
    }

    // MARK: - Overlay channel

    @Test func test_overlay_channel_is_the_first_selected_channel() {
        #expect(makeModel().overlayChannel == "Speed")
    }

    @Test func test_overlay_channel_tracks_the_selection() {
        let model = makeModel()
        model.toggleChannel(ChannelID("Speed")) // deselect Speed
        model.toggleChannel(ChannelID("RPM"))   // RPM is now first
        #expect(model.overlayChannel == "RPM")
    }

    // MARK: - Overlay laps (distance-aligned, from the selected laps)

    @Test func test_overlay_laps_come_from_the_selected_laps() {
        let model = overlaidModel()
        #expect(model.overlayLaps.map(\.id) == [LapID(0), LapID(1)])
        // Re-based per lap → both share one distance axis (criterion: different
        // lengths align).
        #expect(model.overlayLaps[0].distances == [0, 10, 20, 30, 40, 50])
        #expect(model.overlayLaps[1].distances == [0, 10, 20, 30, 40, 50])
        #expect(model.overlayLaps[0].channels["Speed"] == [0, 2, 4, 6, 8, 10])
    }

    @Test func test_overlay_laps_follow_the_overlay_channel() {
        let model = overlaidModel()
        model.toggleChannel(ChannelID("RPM"))   // Speed + RPM
        model.toggleChannel(ChannelID("Speed")) // RPM only → it becomes the overlay channel
        #expect(model.overlayChannel == "RPM")
        #expect(model.overlayLaps[0].channels["RPM"] == [0, 100, 200, 300, 400, 500])
    }

    @Test func test_overlay_is_empty_without_an_analysis_pump() {
        let model = makeModel(analysisPresent: false)
        model.toggleLap(LapID(0))
        model.toggleLap(LapID(1))
        #expect(model.overlayLaps.isEmpty)
        #expect(model.overlayDeltas.isEmpty)
    }

    // MARK: - Delta-t keyed to the reference lap

    @Test func test_overlay_deltas_key_the_reference_against_each_other_lap() {
        let model = overlaidModel() // reference = lap 0
        let strip = model.overlayDeltas[DeltaPair(reference: LapID(0), target: LapID(1))]
        #expect(strip == [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 50, dt: 1.2)])
    }

    @Test func test_setting_the_reference_lap_repoints_the_overlay_deltas() {
        let model = overlaidModel()
        model.setReferenceLap(LapID(1))
        #expect(model.overlayDeltas[DeltaPair(reference: LapID(1), target: LapID(0))]
                == [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 50, dt: -1.2)])
        #expect(model.overlayDeltas[DeltaPair(reference: LapID(0), target: LapID(1))] == nil,
                "the old reference orientation is gone")
    }

    @Test func test_overlay_deltas_empty_with_fewer_than_two_laps() {
        let model = makeModel()
        model.toggleLap(LapID(0)) // only one lap → nothing to compare
        #expect(model.overlayDeltas.isEmpty)
    }
}
