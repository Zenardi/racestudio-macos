import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the kart badge's own text (issue 9.23): typed in the overlay
/// editor, it replaces the kart's text on the badge — in the live HUD and the
/// export — and draws even without a kart; left empty, the badge shows the
/// kart's text again.
@MainActor
@Suite struct KartBadgeTextTests {

    // MARK: - Fixture (no logic — fixed texts and sessions)

    private let english = Locale(identifier: "en")
    private let rect = CGRect(x: 0, y: 0, width: 460, height: 60)
    private let sessionWithoutKart = OverlayRenderFixture.session(kart: nil)

    private func badge(text: String?, session: OverlaySessionContext = OverlayRenderFixture.session())
        -> OverlayWidgetContext {
        OverlayRenderFixture.context(.kartBadge, rect: rect, options: OverlayWidgetOptions(badgeText: text),
                                     session: session)
    }

    private func layout(badgeText: String?) -> OverlayLayout {
        OverlayLayout(name: "Badge", widgets: [
            OverlayWidget(kind: .kartBadge, frame: NormalizedRect(x: 0.03, y: 0.03, width: 0.24, height: 0.06),
                          options: OverlayWidgetOptions(badgeText: badgeText))
        ])
    }

    // MARK: - What the badge says

    /// The typed text replaces the kart's.
    @Test func test_the_badge_shows_the_typed_text() {
        #expect(KartBadgeWidget.text(badge(text: "Team Seven · #7")) == "Team Seven · #7")
    }

    /// Without a typed text the badge shows the kart's, as before.
    @Test func test_without_a_typed_text_the_badge_shows_the_karts() {
        #expect(KartBadgeWidget.text(badge(text: nil)) == OverlayRenderFixture.session().kartBadgeText)
    }

    /// A long text shrinks to fit the badge.
    @Test func test_a_long_text_shrinks_to_fit_the_badge() {
        let text = String(repeating: "W", count: OverlayWidgetOptions.badgeTextLimit)
        let context = badge(text: text)

        let layout = KartBadgeWidget().layout(in: context)

        #expect(layout.style.width(of: text) <= context.content.width - 2 * context.outline + 0.01)
    }

    // MARK: - Kept tidy

    /// The text is trimmed, kept on one line and to its limit; blank is none.
    @Test(arguments: zip(["  Car 7  ", "Car\n7", "Car\r\n7\t", "   ", "\n", ""],
                         ["Car 7", "Car 7", "Car 7", nil, nil, nil] as [String?]))
    func test_the_text_is_trimmed_and_kept_on_one_line(given: String, kept: String?) {
        #expect(OverlayWidgetOptions(badgeText: given).validated().badgeText == kept)
    }

    /// Every line break, tab or control becomes a space; direction overrides
    /// are dropped, so the badge can't be flipped; right-to-left text is kept.
    @Test(arguments: zip(["Car\u{2028}7", "Car\u{2029}7", "Car\u{0085}7", "Car\t7", "Car\u{0}7",
                          "\u{202E}7 raC", "Car \u{2066}7\u{2069}", "سيارة ٧"],
                         ["Car 7", "Car 7", "Car 7", "Car 7", "Car 7", "7 raC", "Car 7", "سيارة ٧"]))
    func test_breaks_controls_and_overrides_are_tidied(given: String, kept: String) {
        #expect(OverlayWidgetOptions(badgeText: given).validated().badgeText == kept)
    }

    /// A text with nothing visible — only zero-width or invisible marks — is
    /// blank, so the badge shows the kart's text.
    @Test(arguments: ["\u{200B}\u{200D}\u{FEFF}", "\u{00AD}", " \u{2060} "])
    func test_invisible_text_is_blank(given: String) {
        #expect(OverlayWidgetOptions(badgeText: given).validated().badgeText == nil)
    }

    /// An emoji joined from several marks counts as one character, and stays
    /// whole at the limit.
    @Test func test_a_joined_emoji_stays_whole_at_the_limit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = String(repeating: "x", count: OverlayWidgetOptions.badgeTextLimit - 1) + family + "y"

        let kept = OverlayWidgetOptions(badgeText: text).validated().badgeText

        #expect(kept?.count == OverlayWidgetOptions.badgeTextLimit)
        #expect(kept?.hasSuffix(family) == true)
    }

    /// Characters stacked with marks are held to a bound in code points, so a
    /// short text can't grow huge.
    @Test func test_stacked_marks_are_held_to_a_bound() {
        let stacked = String(repeating: "e" + String(repeating: "\u{0301}", count: 20),
                             count: OverlayWidgetOptions.badgeTextLimit)

        let kept = OverlayWidgetOptions(badgeText: stacked).validated().badgeText

        #expect((kept?.unicodeScalars.count ?? 0) <= OverlayWidgetOptions.badgeTextScalarLimit)
        #expect(kept?.isEmpty == false)
    }

    /// A text past the limit is cut to it.
    @Test func test_a_text_past_the_limit_is_cut() {
        let long = String(repeating: "é", count: 500)

        let kept = OverlayWidgetOptions(badgeText: long).validated().badgeText

        #expect(kept?.count == OverlayWidgetOptions.badgeTextLimit)
        #expect(OverlayWidgetOptions.badgeTextLimit == 60)
    }

    /// The text is saved with the layout; older layouts, or a value that isn't
    /// text, have none.
    @Test func test_the_text_is_saved_and_older_layouts_have_none() throws {
        let data = try JSONEncoder().encode(layout(badgeText: "Car 7"))
        let older = #"{"name": "Old", "widgets": [{"kind": {"type": "kartBadge"}, "#
            + #""frame": {"x": 0.03, "y": 0.03, "width": 0.24, "height": 0.06}, "options": {"badgeText": 7}}]}"#

        let saved = try JSONDecoder().decode(OverlayLayout.self, from: data)
        let read = try JSONDecoder().decode(OverlayLayout.self, from: Data(older.utf8))

        #expect(saved.widgets[0].options.badgeText == "Car 7")
        #expect(read.widgets[0].options.badgeText == nil)
        #expect(try JSONEncoder().encode(layout(badgeText: nil)).range(of: Data("badgeText".utf8)) == nil)
    }

    // MARK: - Without a kart

    /// A badge with its own text needs no kart; without one it does, as before.
    @Test func test_a_badge_with_its_own_text_needs_no_kart() {
        let withText = layout(badgeText: "Car 7").widgets[0], without = layout(badgeText: nil).widgets[0]

        #expect(withText.availability(for: sessionWithoutKart) == .available)
        #expect(without.availability(for: sessionWithoutKart) == .unavailable(.noKart))
    }

    /// The editor's list and the renderer agree: a badge with text is drawn
    /// without a kart.
    @Test func test_the_editor_and_the_renderer_draw_a_badge_with_text_without_a_kart() {
        let layout = layout(badgeText: "Car 7")

        #expect(layout.availability(for: sessionWithoutKart)["kartBadge"] == .available)
        #expect(layout.drawable(for: .widescreen, session: sessionWithoutKart).map(\.widget.id) == ["kartBadge"])
    }

    /// The export sheet lists a badge with text as one it can draw.
    @Test func test_the_export_sheet_can_switch_on_a_badge_with_text() throws {
        let model = ExportSheetFixture.model(workspaceOverlay: layout(badgeText: "Car 7"),
                                             overlaySession: sessionWithoutKart,
                                             preferences: ExportPreferences(overlay: .workspace))

        let item = try #require(model.widgetItems.first { $0.id == "kartBadge" })

        #expect(item.canSwitchOn && item.isOn)
        #expect(item.reason(locale: english) == nil)
    }

    // MARK: - The editor

    /// The editor sets the badge's text as one undoable step; a blank text
    /// goes back to the kart's.
    @Test func test_the_editor_sets_the_badge_text() {
        let editor = OverlayEditorModel(layout: layout(badgeText: nil))

        editor.setBadgeText("  Car 7 ", for: "kartBadge")
        #expect(editor.layout.widgets[0].options.badgeText == "Car 7")

        editor.setBadgeText("   ", for: "kartBadge")
        #expect(editor.layout.widgets[0].options.badgeText == nil)

        editor.undo()
        #expect(editor.layout.widgets[0].options.badgeText == "Car 7")
    }

    /// The field's placeholder is what the badge says without a typed text:
    /// the kart's text, or *No kart*.
    @Test func test_the_placeholder_is_the_karts_text_or_no_kart() {
        #expect(OverlayRenderFixture.session().kartBadgePlaceholder(locale: english)
                    == OverlayRenderFixture.session().kartBadgeText)
        #expect(sessionWithoutKart.kartBadgePlaceholder(locale: english) == "No kart")
        #expect(sessionWithoutKart.kartBadgePlaceholder(locale: Locale(identifier: "pt-BR")) == "Sem kart")
    }
}
