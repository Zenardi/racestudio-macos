import Testing
@testable import RaceStudioCore

/// Tests for `SplitReportModel` (issue 8.11): the Split Times UI state — the split
/// count, the editable layout (merge / divide / rename / type / lock), the focus,
/// and the pure `report(from:)` assembly over the window's base grid.
@MainActor
@Suite struct SplitReportModelTests {

    @Test func test_defaults_group_the_base_grid_into_three_even_splits() {
        let model = SplitReportModel()
        #expect(model.splitCount == 3)
        #expect(model.layout.base == SplitReportModel.baseResolution)
        #expect(model.layout.splits.count == 3)
        #expect(model.focusedSplit == nil)
    }

    @Test func test_set_split_count_clamps_rebuilds_the_layout_and_clears_focus() {
        let model = SplitReportModel()
        model.focus(model.layout.splits[0].id)
        model.setSplitCount(99)
        #expect(model.splitCount == 12, "clamped to the ceiling")
        #expect(model.layout.splits.count == 12)
        #expect(model.focusedSplit == nil, "a rebuild clears the focus")
        model.setSplitCount(0)
        #expect(model.splitCount == 2, "clamped to the floor")
    }

    @Test func test_merge_reduces_and_divide_increases_the_split_count() {
        let model = SplitReportModel()
        model.merge(model.layout.splits[0].id)
        #expect(model.layout.splits.count == 2)
        model.divide(model.layout.splits[0].id)
        #expect(model.layout.splits.count == 3, "the merged split divides back into two")
    }

    @Test func test_rename_kind_and_lock_flow_through_to_the_layout() {
        let model = SplitReportModel()
        let id = model.layout.splits[1].id
        model.rename(id, to: "Chicane")
        model.setKind(id, to: .corner)
        model.toggleLock(id)
        #expect(model.layout.splits[1].name == "Chicane")
        #expect(model.layout.splits[1].kind == .corner)
        #expect(model.layout.splits[1].locked)
        model.setLocked(id, false)
        #expect(!model.layout.splits[1].locked)
    }

    @Test func test_toggle_lock_is_a_noop_for_an_unknown_split() {
        let model = SplitReportModel()
        let before = model.layout
        model.toggleLock(999)
        #expect(model.layout == before)
    }

    @Test func test_focus_toggles_selects_and_exposes_the_zoom_window() {
        let model = SplitReportModel()
        let id = model.layout.splits[1].id
        model.focus(id)
        #expect(model.focusedSplit == id)
        #expect(model.focusWindow == model.layout.fractionWindow(for: model.layout.splits[1]))
        model.focus(id)
        #expect(model.focusedSplit == nil, "focusing the same split again clears it")
        #expect(model.focusWindow == nil)
        model.focus(999)
        #expect(model.focusedSplit == nil, "an unknown id clears the focus")
    }

    @Test func test_focus_is_dropped_when_the_focused_split_is_merged_away() {
        let model = SplitReportModel()
        let id = model.layout.splits[0].id
        model.focus(id)
        model.merge(id) // merge mints a fresh id, so the focused id is gone
        #expect(model.focusedSplit == nil)
    }

    @Test func test_report_groups_the_base_grid_by_the_current_layout() {
        let model = SplitReportModel()
        // A flat base grid: every one of the 24 cells is 1 s, so each of the three
        // 8-cell splits totals 8 s and the lap totals 24 s.
        let segments = [LapSegments(lap: LapID(0),
                                    baseTimes: Array(repeating: 1.0, count: SplitReportModel.baseResolution))]
        let report = model.report(from: segments)
        #expect(report.rows.count == 1)
        #expect(report.rows[0].times == [8, 8, 8])
        #expect(report.rows[0].total == 24)
    }
}
