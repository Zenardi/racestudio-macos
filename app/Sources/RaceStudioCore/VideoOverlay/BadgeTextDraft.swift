import Combine
import Foundation

/// The overlay editor's *Badge text* field (issue 9.23), as a model: what is
/// typed is a draft for one kart badge, held to the badge's limit, and is given
/// to the editor — one undoable step, none when nothing changed — only when
/// the field is done with (Return, focus leaving, or the field going away).
///
/// The field always shows what the badge keeps: after a commit (trimmed, or
/// empty for a blank text), and after an undo or redo of the badge's text. A
/// change elsewhere in the HUD leaves a draft being typed alone.
@MainActor
public final class BadgeTextDraft: ObservableObject {

    /// The badge the text is typed for.
    public let id: OverlayWidget.ID
    /// What is typed.
    @Published public private(set) var text: String

    private let editor: OverlayEditorModel
    private var watch: AnyCancellable?

    /// A draft for badge `id` in `editor`, starting with its own text.
    public init(editor: OverlayEditorModel, id: OverlayWidget.ID) {
        self.editor = editor
        self.id = id
        self.text = Self.saved(id, in: editor.layout) ?? ""
        watch = editor.$layout.map { Self.saved(id, in: $0) }.removeDuplicates().dropFirst()
            .sink { [weak self] saved in self?.text = saved ?? "" }
    }

    /// Take what is typed, held to ``OverlayWidgetOptions/badgeTextLimit``
    /// characters.
    public func type(_ typed: String) {
        text = String(typed.prefix(OverlayWidgetOptions.badgeTextLimit))
    }

    /// Give the draft to the editor, then show what the badge keeps.
    public func commit() {
        editor.setBadgeText(text, for: id)
        text = Self.saved(id, in: editor.layout) ?? ""
    }

    /// Badge `id`'s own text in `layout`.
    private static func saved(_ id: OverlayWidget.ID, in layout: OverlayLayout) -> String? {
        layout.widgets.first { $0.id == id }?.options.badgeText
    }
}
