import CoreGraphics
import Foundation

/// The overlay editor of the Video + Data view (issue 9.12): the layout being
/// edited, the selected widget, and the history of edits.
///
/// Every edit is one step — a whole drag or resize (``beginGesture()`` …
/// ``endGesture()``), a nudge, a preset, a toggle, an option — and ``undo()`` /
/// ``redo()`` restore the exact layouts on either side of it. The history is
/// bounded at ``historyLimit`` steps. Attach the window's ``undoManager`` and
/// ⌘Z / ⇧⌘Z drive the same history, named for the Edit menu — the only way the
/// shell undoes, so the two never disagree. An edit or an undo made while a
/// drag is still open first records that drag as its own step.
///
/// The geometry — hit-testing in draw order, the 1% grid, the title-safe area
/// and the minimum size — is in `OverlayEditorModel+Geometry.swift`. Pure:
/// no AppKit or SwiftUI; `@MainActor` because the panel reads it there.
@MainActor
public final class OverlayEditorModel: ObservableObject {

    /// How many edits the history keeps; older ones fall off the bottom.
    public static let historyLimit = 100

    /// The layout being edited — live, so the HUD follows a drag as it happens.
    @Published public internal(set) var layout: OverlayLayout

    /// The selected widget, or `nil`.
    @Published public private(set) var selection: OverlayWidget.ID?

    /// Whether the layout differs from the one last loaded or saved.
    @Published public private(set) var isDirty = false

    /// Told the layout after every committed edit, undo and redo — not during a
    /// gesture's live updates — so the window can keep its workspace copy.
    public var onCommit: ((OverlayLayout) -> Void)?

    /// The window's undo manager. Each edit is registered with it, so the Edit
    /// menu's Undo / Redo walk the editor's history. Drive undo through it when
    /// it is attached, so the two stay in step.
    public weak var undoManager: UndoManager?

    @Published private var undoStack: [OverlayLayout] = []
    @Published private var redoStack: [OverlayLayout] = []
    private var savedLayout: OverlayLayout
    /// The layout when the gesture in progress began, or `nil` between gestures.
    var gestureStart: OverlayLayout?

    /// - Parameter layout: the workspace's overlay; `nil` (none chosen yet)
    ///   starts on Kart coaching with the HUD off.
    public init(layout: OverlayLayout?) {
        let start = Self.startingLayout(layout)
        self.layout = start
        self.savedLayout = start
    }

    // MARK: - Loading and saving

    /// Edit another workspace's overlay (`nil` for none yet): the layout is
    /// replaced, and the history, the selection and the dirty flag start afresh.
    public func load(_ layout: OverlayLayout?) {
        let start = Self.startingLayout(layout)
        self.layout = start
        savedLayout = start
        selection = nil
        gestureStart = nil
        undoStack.removeAll()
        redoStack.removeAll()
        undoManager?.removeAllActions(withTarget: self)
        isDirty = false
    }

    /// Forget the edit history — here and in the ``undoManager`` — keeping the
    /// layout: when the panel goes off screen, so ⌘Z in another panel never
    /// edits a HUD out of sight. A drag still open is recorded first, so the
    /// window hears it and a save keeps it.
    public func resetHistory() {
        closeOpenGesture()
        undoStack.removeAll()
        redoStack.removeAll()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Record that the workspace was saved with the current layout.
    public func markSaved() {
        savedLayout = layout
        isDirty = false
    }

    // MARK: - Selection

    /// Select `id`, or nothing for `nil` or an id the layout doesn't hold.
    public func select(_ id: OverlayWidget.ID?) {
        selection = id.flatMap { id in layout.widgets.contains { $0.id == id } ? id : nil }
    }

    // MARK: - History

    /// Whether there is an edit to undo.
    public var canUndo: Bool { !undoStack.isEmpty }

    /// Whether there is an undone edit to redo.
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Step back one edit (closing an open drag first). Returns `false` when
    /// there is none. Internal: the shell undoes through the ``undoManager``.
    @discardableResult
    func undo() -> Bool {
        closeOpenGesture()
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(layout)
        show(previous)
        return true
    }

    /// Step forward one undone edit (closing an open drag first). Returns
    /// `false` when there is none. Internal, like ``undo()``.
    @discardableResult
    func redo() -> Bool {
        closeOpenGesture()
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(layout)
        show(next)
        return true
    }

    // MARK: - Commands

    /// Show or hide the HUD — *Show HUD*. Hiding keeps every widget in place.
    public func setShowsHUD(_ shows: Bool) {
        commit { $0.isEnabled = shows }
    }

    /// Show or hide widget `id`; a hidden widget keeps its place.
    public func setVisible(_ visible: Bool, for id: OverlayWidget.ID) {
        commit { layout in
            guard let index = layout.widgets.firstIndex(where: { $0.id == id }) else { return }
            layout.widgets[index].isVisible = visible
        }
    }

    /// Set widget `id`'s options, validated (``OverlayWidgetOptions/validated()``).
    public func setOptions(_ options: OverlayWidgetOptions, for id: OverlayWidget.ID) {
        commit { layout in
            guard let index = layout.widgets.firstIndex(where: { $0.id == id }) else { return }
            layout.widgets[index].options = options.validated()
        }
    }

    /// Show every widget's numbers in `units`, unless the widget sets its own.
    public func setUnits(_ units: UnitSystem) {
        commit { $0.units = units }
    }

    /// Take `preset`'s name and widgets and switch the HUD on — choosing a preset
    /// is asking to see it. The operator's units and theme are kept.
    public func apply(_ preset: OverlayLayout) {
        commit { layout in
            layout.name = preset.name
            layout.widgets = preset.validated().widgets
            layout.isEnabled = true
        }
    }

    // MARK: - Internals

    /// Apply `change` to the layout as one edit — recorded only if it changed
    /// anything.
    func commit(_ change: (inout OverlayLayout) -> Void) {
        closeOpenGesture()
        var edited = layout
        change(&edited)
        guard edited != layout else { return }
        let before = layout
        layout = edited
        record(before)
    }

    /// Record `before` as the step behind the current layout.
    func record(_ before: OverlayLayout) {
        undoStack.append(before)
        if undoStack.count > Self.historyLimit {
            undoStack.removeFirst(undoStack.count - Self.historyLimit)
        }
        redoStack.removeAll()
        registerUndo()
        didCommit()
    }

    /// Record a drag still in progress as its own step, so what follows lands
    /// after it in the history.
    private func closeOpenGesture() {
        if gestureStart != nil { endGesture() }
    }

    /// Make `restored` the layout after an undo or redo.
    private func show(_ restored: OverlayLayout) {
        layout = restored
        didCommit()
    }

    private func didCommit() {
        if let selection, !layout.widgets.contains(where: { $0.id == selection }) { self.selection = nil }
        isDirty = layout != savedLayout
        onCommit?(layout)
    }

    /// Register the step just recorded with the undo manager. Undoing it there
    /// registers the redo, and redoing registers the undo again — so the Edit
    /// menu walks exactly the editor's history.
    private func registerUndo() {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { editor in editor.undoFromManager() }
        manager.setActionName(L10n.string(.overlayEditorUndoAction))
    }

    private func undoFromManager() {
        guard undo(), let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { editor in editor.redoFromManager() }
        manager.setActionName(L10n.string(.overlayEditorUndoAction))
    }

    private func redoFromManager() {
        guard redo() else { return }
        registerUndo()
    }

    /// What the editor starts on for a workspace's `layout`: it, or Kart coaching
    /// with the HUD off when the workspace has none.
    private static func startingLayout(_ layout: OverlayLayout?) -> OverlayLayout {
        if let layout { return layout }
        var coaching = OverlayPreset.kartCoaching.layout()
        coaching.isEnabled = false
        return coaching
    }
}
