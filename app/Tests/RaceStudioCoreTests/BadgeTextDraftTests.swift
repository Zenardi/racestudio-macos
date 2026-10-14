import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the *Badge text* field's model (issue 9.23, from the review of its
/// first cut): what is typed is a draft for one badge, given to the editor as
/// one step when the field is done with, and the field always shows what the
/// badge keeps — after a commit, an undo, or a blank text.
@MainActor
@Suite struct BadgeTextDraftTests {

    // MARK: - Fixture (no logic — two badges in one layout)

    private func editor(first: String? = nil, second: String? = nil) -> OverlayEditorModel {
        OverlayEditorModel(layout: OverlayLayout(name: "Badges", widgets: [
            OverlayWidget(id: "badge", kind: .kartBadge,
                          frame: NormalizedRect(x: 0.03, y: 0.03, width: 0.24, height: 0.06),
                          options: OverlayWidgetOptions(badgeText: first)),
            OverlayWidget(id: "badge-2", kind: .kartBadge,
                          frame: NormalizedRect(x: 0.03, y: 0.12, width: 0.24, height: 0.06),
                          options: OverlayWidgetOptions(badgeText: second))
        ]))
    }

    private func saved(_ id: String, in editor: OverlayEditorModel) -> String? {
        editor.layout.widgets.first { $0.id == id }?.options.badgeText
    }

    // MARK: - Typing and committing

    /// The field starts with the badge's own text, or empty.
    @Test func test_the_field_starts_with_the_badges_text() {
        let editor = editor(first: "Car 7")

        #expect(BadgeTextDraft(editor: editor, id: "badge").text == "Car 7")
        #expect(BadgeTextDraft(editor: editor, id: "badge-2").text.isEmpty)
    }

    /// Typing changes only the draft; committing gives it to the badge it was
    /// typed for, as one undoable step.
    @Test func test_a_commit_gives_the_draft_to_its_own_badge() {
        let editor = editor()
        let draft = BadgeTextDraft(editor: editor, id: "badge-2")

        draft.type("Team Seven")
        #expect(saved("badge-2", in: editor) == nil)
        draft.commit()

        #expect(saved("badge-2", in: editor) == "Team Seven")
        #expect(saved("badge", in: editor) == nil)
        #expect(editor.canUndo)
    }

    /// Typing is held to the badge's limit.
    @Test func test_typing_is_held_to_the_limit() {
        let draft = BadgeTextDraft(editor: editor(), id: "badge")

        draft.type(String(repeating: "x", count: 80))

        #expect(draft.text.count == OverlayWidgetOptions.badgeTextLimit)
    }

    /// After a commit the field shows what the badge keeps — trimmed, or empty
    /// for a blank text that changed nothing.
    @Test(arguments: zip(["  Car 7  ", "   "], ["Car 7", ""]))
    func test_after_a_commit_the_field_shows_what_the_badge_keeps(typed: String, shown: String) {
        let draft = BadgeTextDraft(editor: editor(), id: "badge")

        draft.type(typed)
        draft.commit()

        #expect(draft.text == shown)
    }

    /// Committing the same text twice records one step.
    @Test func test_an_unchanged_commit_records_nothing() {
        let editor = editor()
        let draft = BadgeTextDraft(editor: editor, id: "badge")
        draft.type("Car 7")
        draft.commit()
        editor.undo()
        #expect(!editor.canUndo)
        editor.redo()

        draft.commit()

        editor.undo()
        #expect(!editor.canUndo)
    }

    /// An undo puts the badge's text back in the field.
    @Test func test_an_undo_puts_the_text_back_in_the_field() {
        let editor = editor(first: "Car 7")
        let draft = BadgeTextDraft(editor: editor, id: "badge")
        draft.type("Car 8")
        draft.commit()

        editor.undo()

        #expect(draft.text == "Car 7")
    }

    /// A change elsewhere in the HUD leaves a draft being typed alone.
    @Test func test_another_edit_leaves_the_draft_alone() {
        let editor = editor()
        let draft = BadgeTextDraft(editor: editor, id: "badge")
        draft.type("Car")

        editor.setShowsHUD(false)

        #expect(draft.text == "Car")
    }
}
