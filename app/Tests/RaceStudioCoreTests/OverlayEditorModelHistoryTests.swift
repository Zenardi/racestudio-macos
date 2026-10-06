import CoreGraphics
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `OverlayEditorModel`'s commands and history (issue 9.12): every
/// edit — a whole drag, a nudge, a preset, a toggle, an option — is one undo
/// step that restores the exact layout; the history is bounded; the dirty flag
/// follows the last save; and the window's `UndoManager` drives the same
/// history (⌘Z / ⇧⌘Z).
@MainActor
@Suite struct OverlayEditorModelHistoryTests {

    private func editor(selecting id: OverlayWidget.ID? = nil) -> OverlayEditorModel {
        OverlayEditorFixture.editor(selecting: id)
    }

    /// A manager that closes each group by hand, as the tests are not run from
    /// an event loop.
    private func manager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    // MARK: - Undo and redo

    /// One gesture — however many updates — is one undo step, and undo and redo
    /// restore the exact layouts on either side of it.
    @Test func test_a_whole_drag_is_one_exactly_reversible_step() {
        let editor = editor(selecting: "trackMap")
        let original = editor.layout

        editor.beginGesture()
        editor.drag(by: CGSize(width: -0.1, height: 0))
        editor.drag(by: CGSize(width: -0.2, height: -0.1))
        editor.endGesture()
        let moved = editor.layout

        #expect(editor.undo())
        #expect(editor.layout == original)
        #expect(!editor.canUndo)
        #expect(editor.redo())
        #expect(editor.layout == moved)
        #expect(!editor.redo(), "nothing left to redo")
    }

    /// A gesture that ends where it began records nothing.
    @Test func test_a_gesture_that_changes_nothing_records_no_step() {
        let editor = editor(selecting: "speed")

        editor.beginGesture()
        editor.drag(by: CGSize(width: 0.001, height: 0.001))
        editor.endGesture()

        #expect(!editor.canUndo)
        #expect(!editor.undo())
    }

    /// A new edit after an undo discards the redo branch.
    @Test func test_a_new_edit_clears_redo() {
        let editor = editor(selecting: "gForce")
        editor.nudge(dx: 1, dy: 0, large: false)
        editor.undo()
        #expect(editor.canRedo)

        editor.nudge(dx: 0, dy: 1, large: false)

        #expect(!editor.canRedo)
    }

    /// The history keeps the last 100 steps: older ones fall off the bottom.
    @Test func test_the_history_is_bounded() {
        let editor = editor(selecting: "gForce")
        var layouts: [OverlayLayout] = []
        for step in 0..<150 {
            layouts.append(editor.layout)
            editor.nudge(dx: step.isMultiple(of: 2) ? 1 : -1, dy: step.isMultiple(of: 3) ? 1 : 0, large: false)
        }

        var undone = 0
        while editor.undo() { undone += 1 }

        #expect(undone == OverlayEditorModel.historyLimit)
        #expect(editor.layout == layouts[150 - OverlayEditorModel.historyLimit])
    }

    /// An undo that removes the selected widget clears the selection.
    @Test func test_undo_drops_a_selection_that_no_longer_exists() {
        let editor = OverlayEditorModel(layout: OverlayPreset.minimal.layout(locale: Locale(identifier: "en")))
        editor.apply(OverlayEditorFixture.layout())
        editor.select("gForce")

        editor.undo()

        #expect(editor.selection == nil)
    }

    // MARK: - Dirty

    /// Dirty means "differs from the last save": an edit dirties, a save cleans,
    /// and undoing back to the saved layout is clean again.
    @Test func test_dirty_follows_the_last_save() {
        let editor = editor(selecting: "speed")
        #expect(!editor.isDirty)

        editor.nudge(dx: 1, dy: 0, large: false)
        #expect(editor.isDirty)

        editor.markSaved()
        #expect(!editor.isDirty)

        editor.undo()
        #expect(editor.isDirty)
        editor.redo()
        #expect(!editor.isDirty)
    }

    // MARK: - Commands

    /// Show HUD off hides the overlay but keeps every widget where it was.
    @Test func test_hiding_the_hud_keeps_the_layout() {
        let editor = editor()

        editor.setShowsHUD(false)

        #expect(!editor.layout.isEnabled)
        #expect(editor.layout.widgets == OverlayEditorFixture.layout().widgets)
        editor.undo()
        #expect(editor.layout.isEnabled)
    }

    /// A widget toggled off keeps its place and comes back with one undo.
    @Test func test_toggling_a_widget_is_undoable() {
        let editor = editor()

        editor.setVisible(false, for: "trackMap")

        #expect(editor.layout.widgets.first { $0.id == "trackMap" }?.isVisible == false)
        editor.undo()
        #expect(editor.layout.widgets.first { $0.id == "trackMap" }?.isVisible == true)
    }

    /// Choosing a preset takes its widgets and switches the HUD on, keeping the
    /// operator's units; a selected widget the preset lacks is deselected.
    @Test func test_applying_a_preset_takes_its_widgets() {
        let editor = OverlayEditorModel(layout: OverlayEditorFixture.layout(isEnabled: false))
        editor.select("gForce")
        let minimal = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))

        editor.apply(minimal)

        #expect(editor.layout.widgets == minimal.widgets)
        #expect(editor.layout.name == minimal.name)
        #expect(editor.layout.isEnabled)
        #expect(editor.layout.units == .imperial)
        #expect(editor.selection == nil)
        #expect(editor.canUndo)
    }

    /// A widget's options are stored validated, as one undoable step.
    @Test func test_widget_options_are_validated_and_undoable() {
        let editor = editor()
        var options = OverlayWidgetOptions()
        options.throttleFullScale = 25
        options.brakeFullScale = -4

        editor.setOptions(options, for: "pedals")

        let stored = editor.layout.widgets.first { $0.id == "pedals" }?.options
        #expect(stored?.throttleFullScale == 25)
        #expect(stored?.brakeFullScale == OverlayWidgetOptions.pedalFullScaleLimits.lowerBound)
        editor.undo()
        #expect(editor.layout.widgets.first { $0.id == "pedals" }?.options == OverlayWidgetOptions())
    }

    /// The overlay's units are one undoable step.
    @Test func test_units_are_undoable() {
        let editor = editor()

        editor.setUnits(.metric)

        #expect(editor.layout.units == .metric)
        editor.undo()
        #expect(editor.layout.units == .imperial)
    }

    /// Commands naming a widget the layout lacks change nothing.
    @Test func test_commands_on_an_unknown_widget_change_nothing() {
        let editor = editor()

        editor.setVisible(false, for: "laser")
        editor.setOptions(OverlayWidgetOptions(maxRPM: 9_000), for: "laser")

        #expect(!editor.canUndo)
    }

    /// The window is told the layout after each committed edit, undo and redo —
    /// never for a gesture's live updates.
    @Test func test_the_window_hears_each_committed_layout() {
        let editor = editor(selecting: "speed")
        var heard: [OverlayLayout] = []
        editor.onCommit = { heard.append($0) }

        editor.beginGesture()
        editor.drag(by: CGSize(width: 0.1, height: 0))
        editor.drag(by: CGSize(width: 0.2, height: 0))
        #expect(heard.isEmpty, "a gesture in progress is not saved yet")
        editor.endGesture()
        editor.undo()
        editor.redo()

        #expect(heard.count == 3)
        #expect(heard.last == editor.layout)
    }

    // MARK: - Loading

    /// A workspace with no overlay starts the editor on Kart coaching with the
    /// HUD off, so nothing is drawn until the operator asks.
    @Test func test_a_workspace_without_an_overlay_starts_on_kart_coaching_with_the_hud_off() {
        let editor = OverlayEditorModel(layout: nil)

        #expect(editor.layout.widgets == OverlayPreset.kartCoaching.layout().widgets)
        #expect(!editor.layout.isEnabled)
        #expect(!editor.isDirty)
    }

    /// Loading another workspace's overlay replaces the layout and forgets the
    /// previous one's history and selection.
    @Test func test_loading_forgets_the_previous_history() {
        let editor = editor(selecting: "speed")
        editor.nudge(dx: 1, dy: 0, large: false)
        let other = OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))

        editor.load(other)

        #expect(editor.layout == other)
        #expect(!editor.canUndo && !editor.canRedo)
        #expect(editor.selection == nil)
        #expect(!editor.isDirty)
    }

    // MARK: - UndoManager (⌘Z / ⇧⌘Z)

    /// The window's undo manager undoes and redoes the editor's steps, named
    /// for the Edit menu.
    @Test func test_the_undo_manager_drives_the_history() {
        let undo = manager()
        let editor = editor(selecting: "speed")
        editor.undoManager = undo
        let original = editor.layout

        undo.beginUndoGrouping()
        editor.nudge(dx: 1, dy: 0, large: false)
        undo.endUndoGrouping()
        let nudged = editor.layout

        #expect(undo.canUndo)
        #expect(undo.undoActionName == L10n.string(.overlayEditorUndoAction))
        undo.undo()
        #expect(editor.layout == original)
        #expect(undo.canRedo)
        undo.redo()
        #expect(editor.layout == nudged)
        #expect(undo.canUndo)
    }

    /// Loading a workspace removes the editor's entries from the undo manager.
    @Test func test_loading_clears_the_undo_manager() {
        let undo = manager()
        let editor = editor(selecting: "speed")
        editor.undoManager = undo
        undo.beginUndoGrouping()
        editor.nudge(dx: 1, dy: 0, large: false)
        undo.endUndoGrouping()

        editor.load(nil)

        #expect(!undo.canUndo)
    }
}
