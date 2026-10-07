import CoreGraphics
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `OverlayEditorModel`'s geometry (issue 9.12): picking the widget
/// under the pointer in draw order, and moving, resizing and nudging it on a 1%
/// grid inside the title-safe area, never below the minimum size. Undo, redo,
/// the dirty flag and the editor's commands are in `OverlayEditorModelHistoryTests`.
///
/// Points and translations are fractions of the preview's video rect, origin
/// top-left — the same space the widgets' ``NormalizedRect``s live in.
@MainActor
@Suite struct OverlayEditorModelTests {

    private let wide = OverlayAspect.widescreen

    private func editor(selecting id: OverlayWidget.ID? = nil) -> OverlayEditorModel {
        OverlayEditorFixture.editor(selecting: id)
    }

    private func frame(_ id: OverlayWidget.ID, in editor: OverlayEditorModel) -> NormalizedRect? {
        OverlayEditorFixture.frame(id, in: editor)
    }

    /// Whether two rects agree to well under a pixel at 8K.
    private func close(_ lhs: NormalizedRect?, _ rhs: NormalizedRect) -> Bool {
        guard let lhs else { return false }
        return [lhs.x - rhs.x, lhs.y - rhs.y, lhs.width - rhs.width, lhs.height - rhs.height]
            .allSatisfy { abs($0) < 1e-9 }
    }

    // MARK: - Hit testing

    /// Where two widgets overlap, the one drawn on top — the higher `z` — is hit.
    @Test func test_hit_testing_picks_the_higher_z_widget() {
        let editor = editor()

        #expect(editor.hitTest(CGPoint(x: 0.12, y: 0.85), aspect: wide) == "gForce")
        #expect(editor.hitTest(CGPoint(x: 0.05, y: 0.95), aspect: wide) == "speed")
    }

    /// Among equal `z`, the widget later in the layout draws on top, so it is hit.
    @Test func test_hit_testing_breaks_a_z_tie_by_layout_order() {
        var layout = OverlayEditorFixture.layout()
        layout.widgets[3].frame = NormalizedRect(x: 0.05, y: 0.85, width: 0.06, height: 0.1)
        let editor = OverlayEditorModel(layout: layout)

        #expect(editor.hitTest(CGPoint(x: 0.08, y: 0.9), aspect: wide) == "pedals")
    }

    /// Empty space and hidden widgets are not hit.
    @Test func test_hit_testing_misses_empty_space_and_hidden_widgets() {
        let editor = editor()
        editor.setVisible(false, for: "gForce")

        #expect(editor.hitTest(CGPoint(x: 0.5, y: 0.5), aspect: wide) == nil)
        #expect(editor.hitTest(CGPoint(x: 0.25, y: 0.75), aspect: wide) == nil, "only the hidden G-ball is there")
        #expect(editor.hitTest(CGPoint(x: 0.12, y: 0.85), aspect: wide) == "speed")
    }

    /// The editor works on the layout even while the HUD is switched off.
    @Test func test_hit_testing_works_with_the_hud_off() {
        let editor = OverlayEditorModel(layout: OverlayEditorFixture.layout(isEnabled: false))

        #expect(editor.hitTest(CGPoint(x: 0.9, y: 0.8), aspect: wide) == "trackMap")
        #expect(editor.editableWidgets(for: wide).count == 4)
    }

    /// Widgets are hit where the preview draws them: in a 4:3 frame the
    /// bottom-right map shrinks toward its corner.
    @Test func test_hit_testing_uses_the_frame_drawn_in_the_preview_aspect() {
        let editor = editor()
        let resolved = OverlayEditorFixture.mapFrame.resolved(in: .standard, anchor: .bottomTrailing)

        #expect(editor.frame(of: "trackMap", in: .standard) == resolved)
        #expect(editor.hitTest(CGPoint(x: resolved.midX, y: resolved.midY), aspect: .standard) == "trackMap")
        #expect(editor.hitTest(CGPoint(x: resolved.minX - 0.005, y: resolved.midY), aspect: .standard) == nil)
    }

    /// A click selects the widget under it; a click on nothing clears it.
    @Test func test_clicking_selects_and_clicking_nothing_deselects() {
        let editor = editor()

        #expect(editor.select(at: CGPoint(x: 0.9, y: 0.8), aspect: wide) == "trackMap")
        #expect(editor.selection == "trackMap")
        #expect(editor.select(at: CGPoint(x: 0.5, y: 0.4), aspect: wide) == nil)
        #expect(editor.selection == nil)
    }

    /// Selecting an id the layout doesn't hold selects nothing.
    @Test func test_selecting_an_unknown_widget_selects_nothing() {
        let editor = editor(selecting: "speed")

        editor.select("laser")

        #expect(editor.selection == nil)
    }

    // MARK: - Drag

    /// A drag moves the selected widget and lands it on the 1% grid.
    @Test func test_dragging_snaps_the_position_to_the_grid() {
        let editor = editor(selecting: "speed")

        editor.drag(by: CGSize(width: 0.0137, height: -0.0262))

        #expect(close(frame("speed", in: editor), NormalizedRect(x: 0.04, y: 0.79, width: 0.14, height: 0.15)))
    }

    /// Every update is measured from where the gesture began, so the result is
    /// the total translation's, not the sum of rounded steps.
    @Test func test_drag_updates_measure_from_the_gesture_start() {
        let editor = editor(selecting: "trackMap")

        editor.beginGesture()
        editor.drag(by: CGSize(width: -0.004, height: -0.004))
        editor.drag(by: CGSize(width: -0.008, height: -0.008))
        editor.drag(by: CGSize(width: -0.012, height: -0.012))
        editor.endGesture()

        #expect(close(frame("trackMap", in: editor), NormalizedRect(x: 0.78, y: 0.64, width: 0.18, height: 0.32)))
    }

    /// A widget dragged past the edge stops at the title-safe margin.
    @Test func test_dragging_stays_inside_the_safe_area() {
        let editor = editor(selecting: "speed")

        editor.drag(by: CGSize(width: -0.5, height: 0.5))

        #expect(close(frame("speed", in: editor), NormalizedRect(x: 0.03, y: 0.82, width: 0.14, height: 0.15)))
        #expect(editor.layout.widgets.allSatisfy { $0.frame.isContained(in: .safeArea(margin: 0.03)) })
    }

    /// Without a selection a drag moves nothing.
    @Test func test_dragging_without_a_selection_changes_nothing() {
        let editor = editor()

        editor.drag(by: CGSize(width: 0.1, height: 0.1))
        editor.endGesture()

        #expect(editor.layout == OverlayEditorFixture.layout())
        #expect(!editor.canUndo)
    }

    // MARK: - Resize

    /// Dragging a corner moves only that corner's two edges, on the grid.
    @Test func test_resizing_a_corner_snaps_its_edges() {
        let editor = editor(selecting: "speed")

        editor.resize(.bottomTrailing, by: CGSize(width: 0.0249, height: -0.0349), aspect: wide)

        #expect(close(frame("speed", in: editor), NormalizedRect(x: 0.03, y: 0.82, width: 0.16, height: 0.12)))
    }

    /// An edge handle moves one edge only.
    @Test func test_resizing_an_edge_moves_only_that_edge() {
        let editor = editor(selecting: "trackMap")

        editor.resize(.leading, by: CGSize(width: -0.05, height: 0.3), aspect: wide)

        #expect(close(frame("trackMap", in: editor), NormalizedRect(x: 0.74, y: 0.65, width: 0.23, height: 0.32)))
    }

    /// A widget can't be squeezed below the minimum size: the dragged corner
    /// stops that far from the opposite one.
    @Test func test_resizing_holds_the_minimum_size() {
        let editor = editor(selecting: "speed")

        editor.resize(.topLeading, by: CGSize(width: 0.5, height: 0.5), aspect: wide)

        #expect(close(frame("speed", in: editor), NormalizedRect(x: 0.14, y: 0.94, width: 0.03, height: 0.03)))
    }

    /// A widget can't be grown past the title-safe margin.
    @Test func test_resizing_stays_inside_the_safe_area() {
        let editor = editor(selecting: "trackMap")

        editor.resize(.topTrailing, by: CGSize(width: 0.4, height: -0.9), aspect: wide)

        #expect(close(frame("trackMap", in: editor), NormalizedRect(x: 0.79, y: 0.03, width: 0.18, height: 0.94)))
    }

    /// In a 4:3 preview the resize is mapped back into the 16:9 frame the layout
    /// is stored in, so the edge drawn in the preview follows the pointer.
    @Test func test_resizing_in_another_aspect_maps_back_to_the_reference_frame() throws {
        let editor = editor(selecting: "speed")
        let before = editor.frame(of: "speed", in: .standard)

        editor.resize(.trailing, by: CGSize(width: 0.06, height: 0), aspect: .standard)

        let after = try #require(editor.frame(of: "speed", in: .standard))
        let start = try #require(before)
        #expect(abs(after.maxX - (start.maxX + 0.06)) <= 0.01, "within one grid step of the pointer")
        #expect(abs(after.minX - start.minX) < 1e-9, "the leading edge stays put")
    }

    // MARK: - Nudge

    /// An arrow key moves the selection one grid step; with ⇧, five.
    @Test func test_arrow_keys_nudge_by_one_or_five_percent() {
        let editor = editor(selecting: "gForce")

        editor.nudge(dx: 1, dy: 0, large: false)
        #expect(close(frame("gForce", in: editor), NormalizedRect(x: 0.11, y: 0.70, width: 0.2, height: 0.2)))

        editor.nudge(dx: 0, dy: -1, large: true)
        #expect(close(frame("gForce", in: editor), NormalizedRect(x: 0.11, y: 0.65, width: 0.2, height: 0.2)))
    }

    /// A nudge into the margin stops at it — and records no step when nothing moved.
    @Test func test_nudging_stops_at_the_safe_area() {
        let editor = editor(selecting: "speed")

        editor.nudge(dx: -1, dy: 0, large: true)

        #expect(close(frame("speed", in: editor), OverlayEditorFixture.speedFrame))
        #expect(!editor.canUndo)
    }

    /// Without a selection the arrow keys move nothing.
    @Test func test_nudging_without_a_selection_changes_nothing() {
        let editor = editor()

        editor.nudge(dx: 1, dy: 1, large: false)

        #expect(editor.layout == OverlayEditorFixture.layout())
    }
}
