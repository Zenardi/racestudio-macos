import Testing
@testable import RaceStudioCore

/// Tests for local-time lap alignment in `LapOverlayViewModel` (issue 8.12): when
/// local-time is on and laps overlay, each lap is shifted so identical track
/// sections — the same elapsed time into the lap — line up across laps.
@Suite struct LapOverlayLocalTimeTests {

    /// Two laps recorded at different session-clock offsets but the same cadence:
    /// lap A starts at t = 100, lap B at t = 250. Each has a landmark sample one
    /// second into the lap (the same corner), so aligning starts must line the
    /// landmarks up too.
    private func overlay() -> LapOverlayViewModel {
        let a = OverlayLap(id: LapID(0), label: "Lap 1",
                           times: [100, 101, 102], distances: [0, 50, 100], channels: ["Speed": [30, 40, 50]])
        let b = OverlayLap(id: LapID(1), label: "Lap 2",
                           times: [250, 251, 252], distances: [0, 50, 100], channels: ["Speed": [32, 42, 52]])
        return LapOverlayViewModel(
            selection: LapSelectionModel(selected: [LapID(0), LapID(1)], reference: LapID(0)),
            laps: [a, b], deltas: [:])
    }

    @Test func test_local_time_traces_align_every_lap_to_a_common_start() {
        let traces = overlay().localTimeTraces(for: "Speed")
        #expect(traces.count == 2)
        #expect(traces[0].xValues(mode: .time) == [0, 1, 2])
        #expect(traces[1].xValues(mode: .time) == [0, 1, 2],
                "the second lap, recorded 150 s later, shifts back to the same origin")
    }

    @Test func test_local_time_lines_up_identical_track_sections() {
        let traces = overlay().localTimeTraces(for: "Speed")
        // The shared landmark is each lap's second sample; after alignment both sit
        // at the same local time, so identical track sections overlap.
        #expect(traces[0].x(at: 1, mode: .time) == traces[1].x(at: 1, mode: .time))
    }

    @Test func test_local_time_leaves_distance_and_value_data_intact() {
        let traces = overlay().localTimeTraces(for: "Speed")
        #expect(traces[1].xValues(mode: .distance) == [0, 50, 100], "distance basis untouched")
        #expect(traces[1].samples.map(\.value) == [32, 42, 52], "values untouched")
        #expect(traces[1].name == "Lap 2")
    }

    @Test func test_local_time_traces_skip_a_channel_no_lap_carries() {
        #expect(overlay().localTimeTraces(for: "Brake").isEmpty)
    }
}
