import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `CursorSelection` (issue 4.7) — the ordered, normalized drag range.
@Suite struct CursorSelectionTests {

    @Test func test_selection_normalizes_reversed_drag() {
        var selection = CursorSelection()
        selection.set(from: 10, to: 3) // dragged right-to-left
        #expect(selection.range == 3...10)
    }

    @Test func test_forward_drag_is_preserved() {
        var selection = CursorSelection()
        selection.set(from: 2, to: 8)
        #expect(selection.range == 2...8)
    }

    @Test func test_fresh_selection_is_empty() {
        let selection = CursorSelection()
        #expect(selection.range == nil)
        #expect(selection.isEmpty)
    }

    @Test func test_zero_width_selection_is_empty() {
        var selection = CursorSelection()
        selection.set(from: 5, to: 5)
        #expect(selection.range == 5...5, "the zero-width range is still recorded")
        #expect(selection.isEmpty, "but a zero-width selection is empty")
    }

    @Test func test_nonzero_width_selection_is_not_empty() {
        var selection = CursorSelection()
        selection.set(from: 1, to: 4)
        #expect(!selection.isEmpty)
    }

    @Test func test_clear_resets_to_empty() {
        var selection = CursorSelection()
        selection.set(from: 1, to: 4)
        selection.clear()
        #expect(selection.range == nil)
        #expect(selection.isEmpty)
    }

    @Test func test_nonfinite_drag_is_ignored() {
        var selection = CursorSelection()
        selection.set(from: 1, to: 4)
        selection.set(from: .nan, to: 5) // ignored — never builds an invalid range
        #expect(selection.range == 1...4)
    }
}
