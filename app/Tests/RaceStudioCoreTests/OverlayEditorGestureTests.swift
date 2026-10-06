import CoreGraphics
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the overlay editor's gesture bookkeeping and its undo manager over
/// several steps (issue 9.12, review findings): a click that doesn't move
/// leaves a widget where it is; an edit, an undo or a nudge made while a drag is
/// still open first closes that drag as its own step, so the history only ever
/// holds layouts the operator actually saw; and the window's `UndoManager`
/// walks every step, drags included.
@MainActor
@Suite struct OverlayEditorGestureTests {

    private func manager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// One edit inside its own undo group, as one event of the run loop would be.
    private func step(_ undo: UndoManager, _ edit: () -> Void) {
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }

    /// A widget off the grid, so any snapping would move it.
    private func offGrid() -> OverlayEditorModel {
        var layout = OverlayEditorFixture.layout()
        layout.widgets[0].frame = NormalizedRect(x: 0.0437, y: 0.8012, width: 0.1433, height: 0.1501)
        let editor = OverlayEditorModel(layout: layout)
        editor.select("speed")
        return editor
    }

    // MARK: - A click that doesn't move

    /// Clicking a widget without moving the pointer leaves it exactly where it
    /// was — no snap, no step.
    @Test func test_a_click_without_movement_changes_nothing() {
        let editor = offGrid()
        let before = editor.layout

        editor.beginGesture()
        editor.drag(by: .zero)
        editor.endGesture()

        #expect(editor.layout == before)
        #expect(!editor.canUndo)
    }

    /// The same for a handle grabbed and let go.
    @Test func test_a_handle_grabbed_without_movement_changes_nothing() {
        let editor = offGrid()
        let before = editor.layout

        editor.beginGesture()
        editor.resize(.bottomTrailing, by: .zero, aspect: .widescreen)
        editor.endGesture()

        #expect(editor.layout == before)
    }

    // MARK: - Edits during an open drag

    /// An undo pressed mid-drag first records the drag, then undoes it: the
    /// layout is the one before the drag, and the drag can be redone.
    @Test func test_undo_during_a_drag_records_the_drag_first() {
        let editor = OverlayEditorFixture.editor(selecting: "trackMap")
        let original = editor.layout

        editor.beginGesture()
        editor.drag(by: CGSize(width: -0.1, height: 0))
        let dragged = editor.layout
        editor.undo()
        editor.endGesture()

        #expect(editor.layout == original)
        #expect(editor.redo())
        #expect(editor.layout == dragged)
    }

    /// A command during a drag (here, toggling a widget) is its own step after
    /// the drag's.
    @Test func test_a_command_during_a_drag_follows_the_drag() {
        let editor = OverlayEditorFixture.editor(selecting: "trackMap")
        let original = editor.layout

        editor.beginGesture()
        editor.drag(by: CGSize(width: -0.1, height: 0))
        let dragged = editor.layout
        editor.setVisible(false, for: "pedals")
        editor.endGesture()

        #expect(editor.undo())
        #expect(editor.layout == dragged)
        #expect(editor.undo())
        #expect(editor.layout == original)
    }

    /// A gesture's widget is found by its id, so a widget reordered during the
    /// gesture is still the one moved.
    @Test func test_the_dragged_widget_is_found_by_id() {
        var layout = OverlayEditorFixture.layout()
        layout.widgets.swapAt(0, 2)
        let editor = OverlayEditorModel(layout: layout)
        editor.select("trackMap")

        editor.drag(by: CGSize(width: -0.1, height: 0))
        editor.endGesture()

        #expect(editor.layout.widgets.first { $0.id == "trackMap" }?.frame.x == 0.69)
        #expect(editor.layout.widgets.first { $0.id == "speed" }?.frame == OverlayEditorFixture.speedFrame)
    }

    // MARK: - The undo manager over several steps

    /// Edit ▸ Undo walks back a drag and a nudge, and Redo forward again, each
    /// restoring the exact layout.
    @Test func test_the_undo_manager_walks_several_steps() {
        let undo = manager()
        let editor = OverlayEditorFixture.editor(selecting: "gForce")
        editor.undoManager = undo
        let original = editor.layout

        step(undo) {
            editor.beginGesture()
            editor.drag(by: CGSize(width: 0.2, height: -0.1))
            editor.endGesture()
        }
        let dragged = editor.layout
        step(undo) { editor.nudge(dx: 1, dy: 0, large: true) }
        let nudged = editor.layout

        undo.undo()
        #expect(editor.layout == dragged)
        undo.undo()
        #expect(editor.layout == original)
        #expect(!undo.canUndo)
        undo.redo()
        undo.redo()
        #expect(editor.layout == nudged)
        #expect(!undo.canRedo)
    }

    /// Leaving the panel forgets the editor's history, in the editor and in the
    /// window's undo manager, so ⌘Z elsewhere never edits a HUD out of sight.
    @Test func test_resetting_the_history_clears_both_stacks() {
        let undo = manager()
        let editor = OverlayEditorFixture.editor(selecting: "gForce")
        editor.undoManager = undo
        step(undo) { editor.nudge(dx: 1, dy: 0, large: false) }
        let layout = editor.layout

        editor.resetHistory()

        #expect(!editor.canUndo && !editor.canRedo)
        #expect(!undo.canUndo)
        #expect(editor.layout == layout, "the layout itself is kept")
    }
}
