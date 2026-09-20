import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `LapSectorTimeline` (issue 9.6): the pure bridge from the session's
/// laps + the 8.11 per-lap base grid + the current ``SplitLayout`` to **absolute
/// session-time windows** for every lap and every sector, plus the reverse
/// lookup that answers "which lap and sector is the cursor in right now?".
///
/// This is what makes video review lap- and sector-aware: the panel seeks by a
/// window, and the readout names the section under the playhead. All value-type
/// math — no FFI, no AVKit — so every behaviour is demonstrable here.
@Suite struct LapSectorTimelineTests {

    // MARK: - Fixtures

    /// Lap 0: starts at 10 s, runs 8 s. Base grid [1, 2, 2, 3] sums to its duration.
    private func lapZero() -> Lap {
        Lap(index: 0, startTimeS: 10, durationS: 8, endTimeS: 18)
    }

    /// Lap 1: starts where lap 0 ends (18 s), runs 6 s. Base grid [1, 1, 2, 2].
    private func lapOne() -> Lap {
        Lap(index: 1, startTimeS: 18, durationS: 6, endTimeS: 24)
    }

    private func segments(_ lap: Int, _ baseTimes: [Double]) -> LapSegments {
        LapSegments(lap: LapID(lap), baseTimes: baseTimes)
    }

    /// Two even splits over a 4-cell base grid: S1 = cells 0..<2, S2 = cells 2..<4.
    private func layout() -> SplitLayout {
        SplitLayout.even(base: 4, count: 2)
    }

    /// The two-lap timeline both navigation and lookup tests read.
    private func timeline() -> LapSectorTimeline {
        LapSectorTimeline.make(
            laps: [lapZero(), lapOne()],
            segments: [segments(0, [1, 2, 2, 3]), segments(1, [1, 1, 2, 2])],
            layout: layout())
    }

    // MARK: - Lap windows

    /// Given a session's laps, when the timeline is built, every lap carries its
    /// absolute `[start, end]` session-time window in session order.
    @Test func test_each_lap_gets_its_absolute_session_window() {
        let built = timeline()

        #expect(built.laps.count == 2)
        #expect(built.laps[0].span == SessionTimeSpan(start: 10, end: 18))
        #expect(built.laps[1].span == SessionTimeSpan(start: 18, end: 24))
        #expect(built.laps[0].lap == LapID(0), "laps keep session order")
    }

    /// A span reports the duration it covers, and a reversed/degenerate span
    /// reports zero rather than a negative length.
    @Test func test_span_duration_is_never_negative() {
        #expect(SessionTimeSpan(start: 10, end: 18).duration == 8)
        #expect(SessionTimeSpan(start: 18, end: 10).duration == 0, "a reversed span has no length")
        #expect(SessionTimeSpan(start: 5, end: 5).duration == 0)
    }

    // MARK: - Sector windows

    /// Given a lap's base grid and the split layout, when the timeline is built,
    /// each split becomes an absolute session-time window: the running sum of the
    /// base cells it spans, offset by the lap's start.
    @Test func test_sectors_accumulate_base_cells_from_the_lap_start() {
        let built = timeline()
        let sectors = built.laps[0].sectors

        #expect(sectors.count == 2, "one sector per split in the layout")
        // S1 spans cells [1, 2] = 3 s from the lap start at 10 s.
        #expect(sectors[0].span == SessionTimeSpan(start: 10, end: 13))
        // S2 spans cells [2, 3] = 5 s, picking up where S1 ended.
        #expect(sectors[1].span == SessionTimeSpan(start: 13, end: 18))
        #expect(sectors[1].span.end == built.laps[0].span.end, "the last sector closes the lap")
    }

    /// Each sector carries the identity the panel needs to label and address it:
    /// its lap, the split id, the split's display name, and its position in track
    /// order.
    @Test func test_sectors_carry_lap_split_identity_and_track_order() {
        let sectors = timeline().laps[0].sectors

        #expect(sectors[0].lap == LapID(0))
        #expect(sectors[0].name == "S1")
        #expect(sectors[0].index == 0)
        #expect(sectors[1].name == "S2")
        #expect(sectors[1].index == 1)
        #expect(sectors[0].splitID != sectors[1].splitID, "split ids address a column uniquely")
        #expect(sectors[0].id != sectors[1].id)
    }

    /// A lap is identified by its index — what the review grid's rows key on.
    @Test func test_lap_span_is_identified_by_its_lap_index() {
        let built = timeline()

        #expect(built.laps[0].id == 0)
        #expect(built.laps[1].id == 1)
    }

    /// The same split in different laps yields different windows — that is the
    /// whole point of sector-by-sector review.
    @Test func test_same_split_differs_per_lap() {
        let built = timeline()

        // Lap 1's grid is [1, 1, 2, 2]: S1 = 2 s, S2 = 4 s, based at 18 s.
        #expect(built.laps[1].sectors[0].span == SessionTimeSpan(start: 18, end: 20))
        #expect(built.laps[1].sectors[1].span == SessionTimeSpan(start: 20, end: 24))
        #expect(built.laps[0].sectors[0].duration != built.laps[1].sectors[0].duration)
    }

    /// Sector durations reproduce the split times the 8.11 report shows, so the
    /// video grid and the Split Times table can never disagree.
    @Test func test_sector_durations_match_the_split_report() {
        let segs = [segments(0, [1, 2, 2, 3])]
        let report = SplitReport.make(from: segs, layout: layout())
        let built = LapSectorTimeline.make(laps: [lapZero()], segments: segs, layout: layout())

        let reported = report.rows[0].times
        let derived = built.laps[0].sectors.map(\.duration)
        #expect(derived.count == reported.count)
        for (a, b) in zip(derived, reported) {
            #expect(abs(a - b) < 1e-9, "the timeline and the split table share one derivation")
        }
    }

    // MARK: - Addressing

    /// A lap and a sector can be looked up by id — what a click in the grid does.
    @Test func test_lap_and_sector_lookup_by_id() {
        let built = timeline()
        let splitID = built.laps[0].sectors[1].splitID

        #expect(built.lapSpan(LapID(1))?.span == SessionTimeSpan(start: 18, end: 24))
        #expect(built.sector(lap: LapID(0), splitID: splitID)?.span == SessionTimeSpan(start: 13, end: 18))
        #expect(built.lapSpan(LapID(9)) == nil, "an unknown lap resolves to nothing")
        #expect(built.sector(lap: LapID(0), splitID: -1) == nil, "an unknown split resolves to nothing")
    }

    /// Every sector across every lap, flattened in track order — the grid's rows.
    @Test func test_flattened_sectors_are_in_session_order() {
        let all = timeline().sectors

        #expect(all.count == 4)
        #expect(all.map(\.span.start) == [10, 13, 18, 20])
    }

    // MARK: - Reverse lookup

    /// Given a cursor time, when it is inside a lap, the timeline names the lap and
    /// the sector holding it — the panel's "Lap 1 · S2" readout.
    @Test func test_reverse_lookup_names_the_lap_and_sector_at_a_time() {
        let built = timeline()

        let early = built.location(atSessionTime: 12)
        #expect(early?.lap == LapID(0))
        #expect(early?.sector?.name == "S1")

        let late = built.location(atSessionTime: 21)
        #expect(late?.lap == LapID(1))
        #expect(late?.sector?.name == "S2")
    }

    /// Sector windows are half-open, so a time exactly on a boundary belongs to the
    /// sector it starts — never to both, never to neither.
    @Test func test_reverse_lookup_boundary_belongs_to_the_starting_sector() {
        let built = timeline()

        #expect(built.location(atSessionTime: 13)?.sector?.name == "S2", "the boundary opens S2")
        #expect(built.location(atSessionTime: 18)?.lap == LapID(1), "a lap boundary opens the next lap")
    }

    /// The very last instant of the session still resolves (to the final sector)
    /// rather than falling off the end of the half-open windows.
    @Test func test_reverse_lookup_resolves_the_final_instant() {
        let built = timeline()
        let atEnd = built.location(atSessionTime: 24)

        #expect(atEnd?.lap == LapID(1))
        #expect(atEnd?.sector?.name == "S2", "the session's last instant closes the final sector")
    }

    /// A time outside every lap — before the first or after the last — resolves to
    /// nothing, so the readout shows no section rather than a wrong one.
    @Test func test_reverse_lookup_outside_the_laps_is_nil() {
        let built = timeline()

        #expect(built.location(atSessionTime: 9.5) == nil, "before the first lap")
        #expect(built.location(atSessionTime: 100) == nil, "after the last lap")
        #expect(built.location(atSessionTime: .nan) == nil, "a non-finite time names no section")
    }

    // MARK: - Degenerate input

    /// A session with no laps yields an empty timeline that answers every query
    /// safely instead of trapping.
    @Test func test_no_laps_yields_an_empty_timeline() {
        let built = LapSectorTimeline.make(laps: [], segments: [], layout: layout())

        #expect(built.isEmpty)
        #expect(built.laps.isEmpty)
        #expect(built.sectors.isEmpty)
        #expect(built.location(atSessionTime: 5) == nil)
        #expect(LapSectorTimeline.empty.isEmpty)
    }

    /// A lap the core produced no base grid for is still navigable at lap
    /// granularity — it simply carries no sectors, rather than vanishing.
    @Test func test_lap_without_a_base_grid_keeps_its_lap_window() {
        let built = LapSectorTimeline.make(
            laps: [lapZero(), lapOne()], segments: [segments(0, [1, 2, 2, 3])], layout: layout())

        #expect(built.laps.count == 2)
        #expect(built.laps[1].sectors.isEmpty, "no grid means no sectors")
        #expect(built.laps[1].span == SessionTimeSpan(start: 18, end: 24), "the lap window survives")
        #expect(built.location(atSessionTime: 20)?.sector == nil, "no sector to name inside it")
    }

    /// A degenerate lap (zero or non-finite duration) is not reviewable, so it is
    /// left out of the timeline entirely.
    @Test func test_degenerate_laps_are_excluded() {
        let zero = Lap(index: 5, startTimeS: 30, durationS: 0, endTimeS: 30)
        let broken = Lap(index: 6, startTimeS: 30, durationS: .nan, endTimeS: .nan)
        let built = LapSectorTimeline.make(
            laps: [lapZero(), zero, broken], segments: [segments(0, [1, 2, 2, 3])], layout: layout())

        #expect(built.laps.count == 1)
        #expect(built.lapSpan(LapID(5)) == nil)
        #expect(built.lapSpan(LapID(6)) == nil)
    }

    /// A layout whose base grid is finer than the times the core returned clamps
    /// instead of reading past the end: the trailing splits collapse to zero-length
    /// windows and the columns still line up with the report.
    @Test func test_layout_finer_than_the_returned_grid_clamps() {
        let built = LapSectorTimeline.make(
            laps: [lapZero()], segments: [segments(0, [1, 2])], layout: SplitLayout.even(base: 4, count: 2))

        let sectors = built.laps[0].sectors
        #expect(sectors.count == 2, "every split still yields a column")
        #expect(sectors[0].span == SessionTimeSpan(start: 10, end: 13), "the cells that exist are used")
        #expect(sectors[1].duration == 0, "the missing cells contribute nothing")
        #expect(built.location(atSessionTime: 13)?.sector == nil, "a zero-length sector holds no instant")
    }

    /// A non-finite base cell cannot poison the running sum — it contributes
    /// nothing, so later sectors keep usable windows.
    @Test func test_nonfinite_base_cells_are_ignored() {
        let built = LapSectorTimeline.make(
            laps: [lapZero()], segments: [segments(0, [1, .nan, 2, 3])], layout: layout())

        let sectors = built.laps[0].sectors
        #expect(sectors[0].span == SessionTimeSpan(start: 10, end: 11), "the NaN cell adds zero")
        #expect(sectors[1].span == SessionTimeSpan(start: 11, end: 16))
        #expect(sectors.allSatisfy { $0.span.start.isFinite && $0.span.end.isFinite })
    }
}
