import Testing
import Foundation
@testable import RaceStudioCore

/// The five named acceptance behaviours for `MultiSessionModel` — parity gap 9.1
/// (multi-session compare, issue #138) — plus the cross-session selection and
/// reference invariant. Covered FFI-free via `MultiSessionFixture`. Session
/// management, channel, delta, and interpolation edges live in
/// `MultiSessionModelEdgeTests`.
@MainActor
@Suite struct MultiSessionModelTests {

    // MARK: - Named acceptance test 1: overlay on a shared axis

    @Test func test_two_sessions_overlay_on_shared_axis() {
        // Given two sessions whose laps have different distance lengths…
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(distScale: 10, valueScale: 2), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(distScale: 12, valueScale: 3), laps: msTwoLaps()))
        // …with one lap selected in each.
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        model.toggleLap(CrossLapID(session: b, lap: LapID(0)))

        // When the overlay is assembled.
        let traces = model.overlayTraces()

        // Then both laps overlay, each re-based to distance 0 (one shared axis)…
        #expect(traces.count == 2)
        #expect(traces[0].trace.samples.first?.distance == 0)
        #expect(traces[1].trace.samples.first?.distance == 0)
        // …their lengths stay independent (parity: different-length laps align)…
        #expect(traces[0].trace.samples.last?.distance == 50)
        #expect(traces[1].trace.samples.last?.distance == 60)
        // …and each is colour-keyed by its session (distinct, per-session).
        #expect(traces[0].session == a)
        #expect(traces[1].session == b)
        #expect(traces[0].color == model.color(for: a))
        #expect(traces[1].color == model.color(for: b))
        #expect(traces[0].color != traces[1].color)
    }

    // MARK: - Named acceptance test 2: cross-session delta-t

    @Test func test_cross_session_delta_t_matches_single_session_case() {
        // The delta of lap 1 vs lap 0 over the reference distance grid, computed
        // by hand from the fixture: dt(d) = t_cmp(d) − t_ref(d) = d/20 − d/10.
        let expected = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 10, dt: -0.5),
                        DeltaSample(distance: 20, dt: -1), DeltaSample(distance: 30, dt: -1.5),
                        DeltaSample(distance: 40, dt: -2), DeltaSample(distance: 50, dt: -2.5)]

        // Single-session case: both laps live in ONE session.
        let single = MultiSessionModel()
        let sA = single.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let singleDelta = single.crossSessionDelta(reference: CrossLapID(session: sA, lap: LapID(0)),
                                                   comparison: CrossLapID(session: sA, lap: LapID(1)))

        // Cross-session case: the comparison lap lives in a *different* session
        // built from identical data.
        let cross = MultiSessionModel()
        let cA = cross.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let cB = cross.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let crossDelta = cross.crossSessionDelta(reference: CrossLapID(session: cA, lap: LapID(0)),
                                                 comparison: CrossLapID(session: cB, lap: LapID(1)))

        #expect(singleDelta == expected)
        #expect(crossDelta == expected)
        #expect(crossDelta == singleDelta, "cross-session delta equals the single-session computation")
    }

    // MARK: - Named acceptance test 3: cursor resolves readouts per session

    @Test func test_cursor_resolves_readouts_per_session() {
        // Two sessions with the same distance basis but different Speed values.
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 100), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))
        model.toggleLap(CrossLapID(session: b, lap: LapID(0)))

        // When the cursor sits at 20 m along the lap.
        let readouts = model.readouts(atDistance: 20)

        // Then each session resolves its own value independently: A = 2·t at
        // t = 2 → 4; B = 100·t at t = 2 → 200.
        #expect(readouts.count == 2)
        #expect(readouts[0].session == a)
        #expect(readouts[0].value == 4)
        #expect(readouts[1].session == b)
        #expect(readouts[1].value == 200)
    }

    // MARK: - Named acceptance test 4: removing a session keeps the other overlays

    @Test func test_removing_a_session_keeps_the_other_overlays() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 2), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 3), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0)))  // reference = (A, lap 0)
        model.toggleLap(CrossLapID(session: b, lap: LapID(0)))

        // When session A is removed.
        model.remove(a)

        // Then B's overlay is intact, its colour is unchanged, and the reference
        // promotes onto B.
        let traces = model.overlayTraces()
        #expect(traces.count == 1)
        #expect(traces[0].session == b)
        #expect(traces[0].color == model.color(for: b))
        #expect(model.sessions == [b])
        #expect(model.selectedLaps == [CrossLapID(session: b, lap: LapID(0))])
        #expect(model.referenceLap == CrossLapID(session: b, lap: LapID(0)))
    }

    // MARK: - Named acceptance test 5: stable colour keys

    @Test func test_session_colour_keys_are_stable() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let c = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))

        // Deterministic by insertion order: the ordered overlay palette.
        #expect(model.color(for: a) == PlotColor.palette[0])
        #expect(model.color(for: b) == PlotColor.palette[1])
        #expect(model.color(for: c) == PlotColor.palette[2])
        #expect(model.colorKey(for: a) == 0)
        #expect(model.colorKey(for: c) == 2)

        // Removing B does not recolour the survivors (colours are per-session,
        // not positional).
        model.remove(b)
        #expect(model.color(for: a) == PlotColor.palette[0])
        #expect(model.color(for: c) == PlotColor.palette[2])
        #expect(model.colorKey(for: c) == 2)

        // A later session takes the next slot, never a freed one.
        let d = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(model.color(for: d) == PlotColor.palette[3])

        // Determinism: an identical add sequence yields identical colours.
        let other = MultiSessionModel()
        let a2 = other.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(other.color(for: a2) == model.color(for: a))
    }

    // MARK: - Selection & reference invariant

    @Test func test_overlay_and_readouts_are_empty_without_a_selection() {
        let model = MultiSessionModel()
        model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        #expect(model.overlayTraces().isEmpty)
        #expect(model.readouts(atDistance: 0).isEmpty)
        #expect(model.referenceLap == nil)
        #expect(model.deltaStrip.isEmpty)
        #expect(model.distanceBounds == nil)
    }

    @Test func test_toggle_selects_then_deselects_a_lap() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let lap = CrossLapID(session: a, lap: LapID(0))
        model.toggleLap(lap)
        #expect(model.selectedLaps == [lap])
        #expect(model.referenceLap == lap)
        model.toggleLap(lap)
        #expect(model.selectedLaps.isEmpty)
        #expect(model.referenceLap == nil, "the reference clears with the last lap")
    }

    @Test func test_first_selected_lap_becomes_the_reference() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let la = CrossLapID(session: a, lap: LapID(0))
        let lb = CrossLapID(session: b, lap: LapID(0))
        model.toggleLap(la)
        model.toggleLap(lb)
        #expect(model.referenceLap == la)
        #expect(model.comparisonTarget == lb)
    }

    @Test func test_set_reference_selects_the_lap_if_needed() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msSpeedBank(valueScale: 1), laps: msTwoLaps()))
        let lap = CrossLapID(session: a, lap: LapID(1))
        model.setReferenceLap(lap)
        #expect(model.selectedLaps == [lap])
        #expect(model.referenceLap == lap)
    }

    @Test func test_delta_strip_uses_the_reference_against_the_comparison_target() {
        let model = MultiSessionModel()
        let a = model.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        let b = model.add(msSession(distance: msDeltaBank(), laps: msTwoLaps()))
        model.toggleLap(CrossLapID(session: a, lap: LapID(0))) // reference
        model.toggleLap(CrossLapID(session: b, lap: LapID(1))) // comparison target
        #expect(model.deltaStrip.last == DeltaSample(distance: 50, dt: -2.5))
    }
}
