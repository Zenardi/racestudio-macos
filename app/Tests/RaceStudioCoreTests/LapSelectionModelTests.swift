import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LapSelectionModel` (issue 4.2) — selected-set + single-reference
/// bookkeeping.
@Suite struct LapSelectionModelTests {

    @Test func test_toggle_adds_and_removes_lap() {
        var model = LapSelectionModel()
        model.toggle(LapID(3))
        #expect(model.selected == [LapID(3)])

        model.toggle(LapID(5))
        #expect(model.selected == [LapID(3), LapID(5)])

        // Toggling an already-selected lap removes it (preserving order).
        model.toggle(LapID(3))
        #expect(model.selected == [LapID(5)])
    }

    @Test func test_first_selection_becomes_reference() {
        var model = LapSelectionModel()
        #expect(model.reference == nil)
        model.toggle(LapID(2))
        // The invariant: a non-empty selection always has a reference.
        #expect(model.reference == LapID(2))
    }

    @Test func test_set_reference_keeps_selection() {
        var model = LapSelectionModel()
        model.toggle(LapID(0))
        model.toggle(LapID(1))
        model.toggle(LapID(2))

        model.setReference(LapID(1))
        #expect(model.reference == LapID(1))
        // Selecting a new reference must not clear the rest of the selection.
        #expect(model.selected == [LapID(0), LapID(1), LapID(2)])
    }

    @Test func test_set_reference_adds_lap_when_not_selected() {
        var model = LapSelectionModel()
        model.toggle(LapID(0))
        model.setReference(LapID(7))
        #expect(model.reference == LapID(7))
        #expect(model.selected == [LapID(0), LapID(7)])
    }

    @Test func test_deselecting_reference_promotes_next() {
        var model = LapSelectionModel()
        model.toggle(LapID(0))
        model.toggle(LapID(1))
        model.toggle(LapID(2))
        model.setReference(LapID(0))

        // Deselecting the reference promotes the next selected lap.
        model.toggle(LapID(0))
        #expect(model.selected == [LapID(1), LapID(2)])
        #expect(model.reference == LapID(1))
    }

    @Test func test_deselecting_last_lap_clears_reference() {
        var model = LapSelectionModel()
        model.toggle(LapID(4))
        #expect(model.reference == LapID(4))
        model.toggle(LapID(4))
        #expect(model.selected.isEmpty)
        #expect(model.reference == nil)
    }

    @Test func test_init_normalizes_reference_to_uphold_invariant() {
        // A non-nil reference with an empty selection is normalized to nil…
        #expect(LapSelectionModel(selected: [], reference: LapID(0)).reference == nil)
        // …a reference not in the selection promotes to the first selected lap…
        #expect(LapSelectionModel(selected: [LapID(1), LapID(2)], reference: LapID(9)).reference == LapID(1))
        // …and a valid reference is kept.
        #expect(LapSelectionModel(selected: [LapID(1), LapID(2)], reference: LapID(2)).reference == LapID(2))
    }

    @Test func test_comparison_target_is_first_non_reference_lap() {
        let model = LapSelectionModel(selected: [LapID(0), LapID(1), LapID(2)], reference: LapID(0))
        #expect(model.comparisonTarget == LapID(1))
        // Only the reference selected → no target.
        #expect(LapSelectionModel(selected: [LapID(0)], reference: LapID(0)).comparisonTarget == nil)
        // Empty selection → no target.
        #expect(LapSelectionModel().comparisonTarget == nil)
    }
}
