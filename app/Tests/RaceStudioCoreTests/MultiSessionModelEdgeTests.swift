import Testing
import Foundation
@testable import RaceStudioCore

/// Session-management, channel, cross-session-delta, and interpolation edge cases
/// for `MultiSessionModel` (parity gap 9.1, issue #138). The five named
/// acceptance behaviours live in `MultiSessionModelTests`; fixtures are shared
/// via `MultiSessionFixture`.
@MainActor
@Suite struct MultiSessionModelEdgeTests {

    // MARK: - Session management

    @Test func test_add_auto_assigns_distinct_ordered_ids() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(a != b)
        #expect(model.sessions == [a, b])
    }

    @Test func test_add_with_an_explicit_id_is_honoured() {
        let model = MultiSessionModel()
        let id = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()),
                           id: SessionID("left"))
        #expect(id == SessionID("left"))
        #expect(model.sessions == [SessionID("left")])
    }

    @Test func test_re_adding_the_same_id_preserves_the_colour_slot() {
        let model = MultiSessionModel()
        model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()), id: SessionID("x"))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let slotB = model.colorKey(for: b)
        // Reload session "x" with new data — its colour slot must not shift.
        model.add(msSession(distance: msSpeedBank(valueScale: 5), laps: msTwoLaps()), id: SessionID("x"))
        #expect(model.colorKey(for: SessionID("x")) == 0)
        #expect(model.colorKey(for: b) == slotB, "reloading one session does not recolour another")
        #expect(model.sessions == [SessionID("x"), b], "reload does not duplicate the session")
    }

    @Test func test_auto_ids_skip_a_conflicting_explicit_id() {
        // An explicit id that looks like an auto id must not be clobbered when a
        // later auto id would otherwise land on it.
        let model = MultiSessionModel()
        model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()),
                  id: SessionID("session-1"))
        let auto = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(auto != SessionID("session-1"))
        #expect(model.sessions.count == 2, "the auto add did not reload the explicit session")
        #expect(model.sessions == [SessionID("session-1"), auto])
    }

    @Test func test_removing_an_unknown_session_is_a_no_op() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        model.remove(SessionID("ghost"))
        #expect(model.sessions == [a])
    }

    @Test func test_unknown_session_has_no_colour_key_and_a_neutral_colour() {
        let model = MultiSessionModel()
        #expect(model.colorKey(for: SessionID("ghost")) == nil)
        #expect(model.color(for: SessionID("ghost")) == .unselected)
        #expect(model.analysis(for: SessionID("ghost")) == nil)
    }

    @Test func test_analysis_is_reachable_for_a_known_session() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(model.analysis(for: a) != nil)
    }

    @Test func test_session_label_prefers_metadata_then_falls_back_to_id() {
        let model = MultiSessionModel()
        let named = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps(),
                                        name: "Qualifying"))
        let blank = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()),
                              id: SessionID("session-2"))
        #expect(model.sessionLabel(for: named) == "Qualifying")
        #expect(model.sessionLabel(for: blank) == "session-2")
        #expect(model.sessionLabel(for: SessionID("ghost")) == "ghost")
    }

    // MARK: - Overlay channel

    @Test func test_channel_defaults_to_the_first_channel_of_the_first_session() {
        let model = MultiSessionModel()
        model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(model.channel == "Speed")
    }

    @Test func test_overlay_is_empty_for_an_unknown_channel() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        model.setChannel("Nope")
        #expect(model.overlayTraces().isEmpty, "no such channel → nothing to overlay")
        #expect(model.readouts(atDistance: 20).first?.value == nil)
    }

    @Test func test_setting_the_same_channel_is_a_no_op() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        model.setChannel("Speed") // already the default
        #expect(model.overlayTraces().count == 1)
    }

    @Test func test_overlay_follows_a_channel_change() {
        // A second channel with distinct values selected via setChannel.
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "Speed", unit: "km/h", sampleRateHz: 10, decimals: 1, sampleCount: 11),
                       Channel(name: "RPM", unit: "rpm", sampleRateHz: 10, decimals: 0, sampleCount: 11)],
            laps: msTwoLaps())
        let source = FakeSessionDataSource(
            banks: [], distanceBanks: [msSpeedBank(valueScale: 2), msSpeedBank(valueScale: 1000)])
        let model = MultiSessionModel()
        let a = model.add(AnalysisSession(session: session, dataSource: source))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))

        model.setChannel("RPM")
        #expect(model.channel == "RPM")
        // RPM at 20 m (t = 2) → 1000·2 = 2000.
        #expect(model.readouts(atDistance: 20).first?.value == 2000)
    }

    @Test func test_overlay_trace_and_readout_expose_stable_identity() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()),
                          id: SessionID("run-a"))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        // Stable per-(session, lap) identity for SwiftUI diffing.
        #expect(model.overlayTraces().first?.id == "run-a#0")
        #expect(model.readouts(atDistance: 0).first?.id == "run-a#0")
    }

    // MARK: - Cross-session delta edges

    @Test func test_delta_of_a_lap_against_itself_is_all_zero() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let lap = CrossLapID(session: a, lap: LapID(0))
        let delta = model.crossSessionDelta(reference: lap, comparison: lap)
        #expect(delta.allSatisfy { $0.dt == 0 })
        #expect(delta.count == 6)
    }

    @Test func test_delta_for_an_unknown_lap_is_empty() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let known = CrossLapID(session: a, lap: LapID(0))
        let unknownLap = CrossLapID(session: a, lap: LapID(99))
        let unknownSession = CrossLapID(session: SessionID("ghost"), lap: LapID(0))
        #expect(model.crossSessionDelta(reference: known, comparison: unknownLap).isEmpty)
        #expect(model.crossSessionDelta(reference: unknownSession, comparison: known).isEmpty)
    }

    // MARK: - Distance bounds & cursor clamping

    @Test func test_distance_bounds_track_the_reference_lap() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(distScale: 10, valueScale: 1), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        #expect(model.distanceBounds == 0...50)
    }

    @Test func test_readouts_clamp_beyond_the_lap_distance() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        // Past the lap end (max 50 m): clamps to the last value (2·5 = 10).
        #expect(model.readouts(atDistance: 999).first?.value == 10)
        // Before the lap start: clamps to the first value (0).
        #expect(model.readouts(atDistance: -5).first?.value == 0)
    }

    // MARK: - Pure interpolation / delta primitives (internal, covered directly)

    @Test func test_distance_domain_delta_with_no_comparison_samples_is_empty() {
        let reference = OverlayLap(id: LapID(0), label: "Lap 1", times: [0, 1], distances: [0, 10],
                                   channels: [:])
        let empty = OverlayLap(id: LapID(1), label: "Lap 2", times: [], distances: [], channels: [:])
        #expect(MultiSessionModel.distanceDomainDelta(reference: reference, comparison: empty).isEmpty)
    }

    @Test func test_distance_domain_delta_clamps_past_the_comparison_range() {
        // Reference extends to 100 m; comparison only to 50 m → the comparison
        // time flatlines at its last value past 50 m.
        let reference = OverlayLap(id: LapID(0), label: "Lap 1", times: [0, 5, 10],
                                   distances: [0, 50, 100], channels: [:])
        let comparison = OverlayLap(id: LapID(1), label: "Lap 2", times: [0, 4],
                                    distances: [0, 50], channels: [:])
        let delta = MultiSessionModel.distanceDomainDelta(reference: reference, comparison: comparison)
        // At 100 m: t_cmp clamps to 4, t_ref = 10 → dt = −6.
        #expect(delta.last == DeltaSample(distance: 100, dt: -6))
    }

    @Test func test_sample_interpolates_clamps_and_handles_empty_input() {
        #expect(MultiSessionModel.sample(1, xs: [], ys: []) == nil)
        // Linear midpoint of a single segment.
        #expect(MultiSessionModel.sample(5, xs: [0, 10], ys: [0, 20]) == 10)
        // A plateau resolves to the value entering the flat step.
        #expect(MultiSessionModel.sample(10, xs: [0, 10, 10, 20], ys: [0, 1, 5, 9]) == 1)
    }
}
