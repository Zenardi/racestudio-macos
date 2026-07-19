import Testing
@testable import RaceStudioCore

/// Tests for `SplitReport.make` (issue 8.11): the pure assembly of the split-times
/// table plus the best theoretical (per-split minima) and best rolling
/// (one-lap-length window over the base grid) laps from the FFI base grid.
@Suite struct SplitReportTests {

    private func lap(_ index: Int, _ times: [Double]) -> LapSegments {
        LapSegments(lap: LapID(index), baseTimes: times)
    }

    // MARK: - Table

    @Test func test_each_row_sums_the_base_cells_within_each_split() {
        // base 6, three splits of two cells: [0..2), [2..4), [4..6).
        let layout = SplitLayout.even(base: 6, count: 3)
        let report = SplitReport.make(from: [
            lap(0, [1, 1, 1, 1, 1, 1]),
            lap(1, [3, 1, 1, 1, 1, 1])
        ], layout: layout)

        #expect(report.rows.map(\.lap) == [LapID(0), LapID(1)])
        #expect(report.rows[0].times == [2, 2, 2])
        #expect(report.rows[0].total == 6)
        #expect(report.rows[1].times == [4, 2, 2], "the extra second lands in split 1")
    }

    @Test func test_empty_segments_yield_an_empty_report() {
        let report = SplitReport.make(from: [], layout: SplitLayout.even(base: 6, count: 3))
        #expect(report.rows.isEmpty)
        #expect(report.isEmpty)
        #expect(report.bestTheoretical.total == 0)
        #expect(report.bestRolling.total == 0)
        #expect(report.bestRolling.startLap == nil)
        #expect(report.bestTheoretical.perSplit.allSatisfy { $0.lap == nil })
    }

    @Test func test_a_split_range_past_the_base_times_is_clamped_not_trapped() {
        // A single split spanning [0..6) over a lap that only carries 4 base cells:
        // the sum clamps to the four available cells instead of over-reading.
        let layout = SplitLayout.even(base: 6, count: 1)
        let report = SplitReport.make(from: [lap(0, [1, 2, 3, 4])], layout: layout)
        #expect(report.rows[0].times == [10])
    }

    // MARK: - Best theoretical

    @Test func test_best_theoretical_stitches_the_fastest_section_from_each_lap() {
        // Lap 0 is fast in the first half, lap 1 in the second; the theoretical lap
        // takes the best of each split and beats both real laps (6 s vs 22 s).
        let layout = SplitLayout.even(base: 6, count: 3)
        let report = SplitReport.make(from: [
            lap(0, [1, 1, 1, 1, 9, 9]),
            lap(1, [9, 9, 1, 1, 1, 1])
        ], layout: layout)

        #expect(report.rows[0].total == 22 && report.rows[1].total == 22)
        #expect(report.bestTheoretical.total == 6)
        #expect(report.bestTheoretical.perSplit[0].lap == LapID(0), "lap 0 owns the fast first split")
        #expect(report.bestTheoretical.perSplit[2].lap == LapID(1), "lap 1 owns the fast last split")
    }

    @Test func test_best_theoretical_breaks_ties_toward_the_earlier_lap() {
        let layout = SplitLayout.even(base: 2, count: 1)
        let report = SplitReport.make(from: [lap(0, [5, 5]), lap(1, [5, 5])], layout: layout)
        #expect(report.bestTheoretical.perSplit[0].lap == LapID(0))
        #expect(report.bestTheoretical.perSplit[0].time == 10)
    }

    // MARK: - Best rolling

    @Test func test_best_rolling_finds_the_fastest_contiguous_lap_across_a_boundary() {
        // Two laps whose fast halves meet at the start/finish line: the fastest
        // one-lap-length (6-cell) window straddles the crossing, at lap 0 cell 3.
        let layout = SplitLayout.even(base: 6, count: 3)
        let report = SplitReport.make(from: [
            lap(0, [9, 9, 9, 1, 1, 1]),
            lap(1, [1, 1, 1, 9, 9, 9])
        ], layout: layout)

        #expect(report.bestRolling.total == 6)
        #expect(report.bestRolling.startLap == LapID(0))
        #expect(report.bestRolling.startCell == 3)
    }

    @Test func test_best_rolling_without_a_full_lap_of_data_returns_the_whole_stream() {
        // A lap carrying fewer base cells than the layout's window: there is no full
        // lap to slide, so the whole (short) stream is the best rolling estimate.
        let layout = SplitLayout.even(base: 6, count: 2)
        let report = SplitReport.make(from: [lap(4, [1, 2, 3])], layout: layout)
        #expect(report.bestRolling.total == 6)
        #expect(report.bestRolling.startLap == LapID(4))
        #expect(report.bestRolling.startCell == 0)
    }

    // MARK: - Value-type identity + totals (SwiftUI diffing)

    @Test func test_lap_segments_id_and_total_derive_from_the_lap_and_base_times() {
        let segments = LapSegments(lap: LapID(2), baseTimes: [1, 2, 3])
        #expect(segments.id == 2)
        #expect(segments.total == 6)
    }

    @Test func test_report_row_and_split_best_ids_drive_swiftui_diffing() {
        let report = SplitReport.make(from: [lap(0, [1, 1])], layout: SplitLayout.even(base: 2, count: 1))
        #expect(report.rows[0].id == 0, "a row is identified by its lap")
        #expect(report.bestTheoretical.perSplit[0].id == report.splits[0].id,
                "a best-split is identified by its split")
    }
}
