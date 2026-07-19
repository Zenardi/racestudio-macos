import Testing
@testable import RaceStudioCore

/// Tests for `SplitLayout` (issue 8.11): the editable partition of a lap's fine
/// base grid into splits — even partitioning, and the pure merge / divide / rename
/// / type / lock operations that keep the ranges tiling `[0, base)`.
@Suite struct SplitLayoutTests {

    /// The base cells covered by `splits`, in order — used to assert the ranges tile
    /// `[0, base)` with no gap or overlap after an edit.
    private func coverage(_ layout: SplitLayout) -> [Int] {
        layout.splits.flatMap { Array($0.range) }
    }

    // MARK: - Even partition

    @Test func test_even_partition_tiles_the_base_grid_in_order() {
        let layout = SplitLayout.even(base: 24, count: 3)
        #expect(layout.base == 24)
        #expect(layout.splits.map(\.range) == [0..<8, 8..<16, 16..<24])
        #expect(layout.splits.map(\.name) == ["S1", "S2", "S3"])
        #expect(layout.splits.allSatisfy { $0.kind == .straight && !$0.locked })
    }

    @Test func test_even_partition_spreads_the_remainder_across_the_leading_splits() {
        // 10 cells into 3 splits: 4, 3, 3 — the leftover cell goes to the first split.
        let layout = SplitLayout.even(base: 10, count: 3)
        #expect(layout.splits.map(\.range) == [0..<4, 4..<7, 7..<10])
        #expect(coverage(layout) == Array(0..<10), "every base cell is covered exactly once")
    }

    @Test func test_even_partition_clamps_the_count_to_the_base() {
        #expect(SplitLayout.even(base: 4, count: 0).splits.count == 1, "at least one split")
        #expect(SplitLayout.even(base: 4, count: 99).splits.count == 4, "no more splits than cells")
    }

    @Test func test_even_partition_of_a_nonpositive_base_is_a_single_empty_split() {
        let layout = SplitLayout.even(base: 0, count: 3)
        #expect(layout.splits.count == 1)
        #expect(layout.splits[0].range == 0..<0)
    }

    // MARK: - Merge

    @Test func test_merging_joins_a_split_into_its_successor() {
        let layout = SplitLayout.even(base: 24, count: 3)
        let merged = layout.merging(layout.splits[0].id)
        #expect(merged.splits.map(\.range) == [0..<16, 16..<24])
        #expect(merged.splits[0].name == "S1", "the merged split keeps the earlier name")
        #expect(coverage(merged) == Array(0..<24))
    }

    @Test func test_merging_the_last_split_joins_its_predecessor() {
        let layout = SplitLayout.even(base: 24, count: 3)
        let merged = layout.merging(layout.splits[2].id)
        #expect(merged.splits.map(\.range) == [0..<8, 8..<24])
    }

    @Test func test_merging_is_a_noop_for_a_single_split() {
        let layout = SplitLayout.even(base: 24, count: 1)
        #expect(layout.merging(layout.splits[0].id) == layout)
    }

    @Test func test_merging_is_refused_when_the_split_or_its_partner_is_locked() {
        let layout = SplitLayout.even(base: 24, count: 3)
        let locked = layout.settingLocked(layout.splits[1].id, to: true)
        // Merging split 0 would consume the locked split 1 → refused, layout unchanged.
        #expect(locked.merging(locked.splits[0].id) == locked)
    }

    // MARK: - Divide

    @Test func test_dividing_splits_at_the_midpoint() {
        let layout = SplitLayout.even(base: 24, count: 1)
        let divided = layout.dividing(layout.splits[0].id)
        #expect(divided.splits.map(\.range) == [0..<12, 12..<24])
        #expect(divided.splits.map(\.name) == ["S1", "S1 2"])
        #expect(coverage(divided) == Array(0..<24))
    }

    @Test func test_dividing_is_a_noop_for_a_single_cell_split() {
        let layout = SplitLayout.even(base: 3, count: 3) // each split is one cell
        #expect(layout.dividing(layout.splits[0].id) == layout)
    }

    @Test func test_dividing_is_refused_for_a_locked_split() {
        let layout = SplitLayout.even(base: 24, count: 1)
        let locked = layout.settingLocked(layout.splits[0].id, to: true)
        #expect(locked.dividing(locked.splits[0].id) == locked)
    }

    // MARK: - Rename / kind / lock

    @Test func test_rename_kind_and_lock_update_the_named_split_only() {
        let layout = SplitLayout.even(base: 24, count: 3)
        let id = layout.splits[1].id
        let edited = layout.renaming(id, to: "Esses")
            .settingKind(id, to: .corner)
            .settingLocked(id, to: true)
        #expect(edited.splits[1].name == "Esses")
        #expect(edited.splits[1].kind == .corner)
        #expect(edited.splits[1].locked)
        #expect(edited.splits[0] == layout.splits[0], "other splits are untouched")
    }

    @Test func test_edits_are_noops_for_an_unknown_id() {
        let layout = SplitLayout.even(base: 24, count: 3)
        #expect(layout.merging(999) == layout)
        #expect(layout.dividing(999) == layout)
        #expect(layout.renaming(999, to: "x") == layout)
        #expect(layout.settingKind(999, to: .corner) == layout)
        #expect(layout.settingLocked(999, to: true) == layout)
    }

    @Test func test_merge_and_divide_mint_fresh_unique_ids() {
        let layout = SplitLayout.even(base: 24, count: 3)
        let ids = Set(layout.merging(layout.splits[0].id).splits.map(\.id))
        #expect(ids.count == 2, "the merged split has a fresh, still-unique id")
        let dividedIDs = layout.dividing(layout.splits[0].id).splits.map(\.id)
        #expect(Set(dividedIDs).count == dividedIDs.count, "divide's two halves get distinct ids")
    }

    // MARK: - Fraction window

    @Test func test_fraction_window_maps_the_split_span_to_a_lap_fraction() {
        let layout = SplitLayout.even(base: 24, count: 4) // splits of 6 cells
        #expect(layout.fractionWindow(for: layout.splits[1]) == 0.25...0.5)
    }

    @Test func test_fraction_window_of_a_degenerate_base_is_zero() {
        let layout = SplitLayout.even(base: 0, count: 3)
        #expect(layout.fractionWindow(for: layout.splits[0]) == 0...0)
    }

    @Test func test_cell_count_reports_the_span() {
        let layout = SplitLayout.even(base: 24, count: 3)
        #expect(layout.splits[0].cellCount == 8)
    }

    @Test func test_split_kind_titles_and_ids_label_the_type_picker() {
        #expect(SplitKind.straight.title == "Straight")
        #expect(SplitKind.corner.title == "Corner")
        #expect(SplitKind.straight.id == "straight")
        #expect(SplitKind.allCases == [.straight, .corner])
    }
}
