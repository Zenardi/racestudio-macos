import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for saving the Split Times splits with the workspace (issue 9.20): a
/// ``SplitLayout`` round-trips exactly, an impossible one is refused rather
/// than restored, and the report takes a saved layout back.
@MainActor
@Suite struct SplitLayoutCodingTests {

    // MARK: - Fixture (no logic — fixed edits)

    /// Four splits with every kind of edit: a merge, a divide, a rename, a type
    /// and a lock.
    private var edited: SplitLayout {
        SplitLayout.even(base: 24, count: 4)
            .merging(0)
            .dividing(2)
            .renaming(1, to: "Hairpin")
            .settingKind(1, to: .corner)
            .settingLocked(3, to: true)
    }

    private func roundTrip(_ layout: SplitLayout) throws -> SplitLayout {
        try JSONDecoder().decode(SplitLayout.self, from: JSONEncoder().encode(layout))
    }

    private func decode(_ json: String) throws -> SplitLayout {
        try JSONDecoder().decode(SplitLayout.self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    /// Every edit survives, and so does the id source: a split divided after
    /// the reload never reuses a live id.
    @Test func test_an_edited_layout_round_trips_exactly() throws {
        let layout = edited

        let loaded = try roundTrip(layout)

        #expect(loaded == layout)
        #expect(loaded.dividing(loaded.splits[0].id) == layout.dividing(layout.splits[0].id))
    }

    /// An unknown split type reads as a straight.
    @Test func test_an_unknown_kind_reads_as_a_straight() throws {
        let layout = try decode(#"""
            {"base": 2, "nextID": 2, "splits": [
              {"id": 0, "name": "S1", "kind": "chicane", "locked": false, "start": 0, "end": 1},
              {"id": 1, "name": "S2", "kind": "corner", "locked": true, "start": 1, "end": 2}]}
            """#)

        #expect(layout.splits.map(\.kind) == [.straight, .corner])
        #expect(layout.splits.map(\.locked) == [false, true])
    }

    /// A stale id source is moved past the live ids.
    @Test func test_a_stale_id_source_is_moved_past_the_live_ids() throws {
        let layout = try decode(#"""
            {"base": 4, "nextID": 0, "splits": [
              {"id": 4, "name": "S1", "kind": "straight", "locked": false, "start": 0, "end": 2},
              {"id": 7, "name": "S2", "kind": "straight", "locked": false, "start": 2, "end": 4}]}
            """#)

        #expect(layout.dividing(4).splits.map(\.id) == [8, 9, 7])
    }

    // MARK: - Refused

    /// Layouts whose splits don't tile the base grid exactly, once each: a gap,
    /// an overlap, a split past the end, an empty split, a repeated id, no
    /// splits at all, a first split that doesn't start at 0, and an empty grid.
    nonisolated private static let impossibleLayouts: [String] = [
        #"{"base": 4, "nextID": 2, "splits": ["#
            + #"{"id": 0, "name": "S1", "start": 0, "end": 1}, {"id": 1, "name": "S2", "start": 2, "end": 4}]}"#,
        #"{"base": 4, "nextID": 2, "splits": ["#
            + #"{"id": 0, "name": "S1", "start": 0, "end": 3}, {"id": 1, "name": "S2", "start": 2, "end": 4}]}"#,
        #"{"base": 4, "nextID": 2, "splits": ["#
            + #"{"id": 0, "name": "S1", "start": 0, "end": 2}, {"id": 1, "name": "S2", "start": 2, "end": 5}]}"#,
        #"{"base": 4, "nextID": 2, "splits": ["#
            + #"{"id": 0, "name": "S1", "start": 0, "end": 0}, {"id": 1, "name": "S2", "start": 0, "end": 4}]}"#,
        #"{"base": 4, "nextID": 2, "splits": ["#
            + #"{"id": 0, "name": "S1", "start": 0, "end": 2}, {"id": 0, "name": "S2", "start": 2, "end": 4}]}"#,
        #"{"base": 4, "nextID": 2, "splits": []}"#,
        #"{"base": 4, "nextID": 2, "splits": [{"id": 0, "name": "S1", "start": 1, "end": 4}]}"#,
        #"{"base": 0, "nextID": 1, "splits": [{"id": 0, "name": "S1", "start": 0, "end": 0}]}"#
    ]

    /// An impossible layout is refused rather than restored.
    @Test(arguments: impossibleLayouts)
    func test_an_impossible_layout_is_refused(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    // MARK: - The report takes it back

    /// The report restores a saved layout, with a split count that matches it
    /// and no focus.
    @Test func test_the_report_restores_a_saved_layout() {
        let report = SplitReportModel()
        report.focus(report.layout.splits[0].id)
        let layout = SplitLayout.even(base: SplitReportModel.baseResolution, count: 5).renaming(2, to: "Kink")

        report.restore(layout)

        #expect(report.layout == layout)
        #expect(report.splitCount == 5)
        #expect(report.focusedSplit == nil)
    }

    /// A merged-down layout keeps its single split; the count control stays in
    /// its range.
    @Test func test_a_single_split_layout_keeps_the_count_in_range() {
        let report = SplitReportModel()
        let layout = SplitLayout.even(base: SplitReportModel.baseResolution, count: 2).merging(0)

        report.restore(layout)

        #expect(report.layout.splits.count == 1)
        #expect(report.splitCount == SplitReportModel.splitCountRange.lowerBound)
    }

    /// A layout over another base grid can't be read by this report, so it is
    /// ignored.
    @Test func test_a_layout_over_another_grid_is_ignored() {
        let report = SplitReportModel()
        let before = report.layout

        report.restore(SplitLayout.even(base: 10, count: 2))

        #expect(report.layout == before)
        #expect(report.splitCount == 3)
    }
}
