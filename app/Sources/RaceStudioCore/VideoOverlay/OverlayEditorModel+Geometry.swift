import CoreGraphics
import Foundation

/// A handle on a selected widget's corner or edge (issue 9.12): which edges a
/// resize drag moves.
public enum OverlayResizeHandle: String, CaseIterable, Sendable {
    case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing

    /// Whether the drag moves the left edge.
    public var movesLeading: Bool { [.topLeading, .leading, .bottomLeading].contains(self) }
    /// Whether the drag moves the right edge.
    public var movesTrailing: Bool { [.topTrailing, .trailing, .bottomTrailing].contains(self) }
    /// Whether the drag moves the top edge.
    public var movesTop: Bool { [.topLeading, .top, .topTrailing].contains(self) }
    /// Whether the drag moves the bottom edge.
    public var movesBottom: Bool { [.bottomLeading, .bottom, .bottomTrailing].contains(self) }
}

/// The editor's geometry (issue 9.12): which widget is under the pointer, and
/// moving, resizing and nudging the selected one on a 1% grid, inside the
/// title-safe area, never below ``OverlayLayout/minimumWidgetSize``.
///
/// Points and translations are fractions of the preview's video rect, origin
/// top-left. The layout is stored in the 16:9 reference frame: a move is the
/// same there as in any output (only sizes differ between aspects), and a
/// resize is mapped back with ``NormalizedRect/reference(from:in:anchor:safeMargin:)``.
/// Positions snap on the reference frame's grid — the preview's own grid for
/// 16:9 footage.
public extension OverlayEditorModel {

    /// The grid every move and resize snaps to: 1% of the frame.
    static let gridStep = 0.01
    /// The grid steps an arrow key moves with ⇧ held.
    static let largeNudgeSteps = 5

    /// Every visible widget as the preview draws it in `aspect`, back to front —
    /// even while the HUD is off, so it can be arranged before it is shown.
    func editableWidgets(for aspect: OverlayAspect) -> [ResolvedOverlayWidget] {
        var shown = layout
        shown.isEnabled = true
        return shown.resolved(for: aspect)
    }

    /// Where widget `id` is drawn in `aspect`, or `nil` when it is hidden or
    /// unknown — where its selection handles go.
    func frame(of id: OverlayWidget.ID, in aspect: OverlayAspect) -> NormalizedRect? {
        editableWidgets(for: aspect).first { $0.id == id }?.frame
    }

    /// The top-most visible widget at `point` — the higher `z`, then the later
    /// in the layout, as drawn — or `nil` over empty space.
    func hitTest(_ point: CGPoint, aspect: OverlayAspect) -> OverlayWidget.ID? {
        let x = Double(point.x), y = Double(point.y)
        return editableWidgets(for: aspect).last { widget in
            let frame = widget.frame
            return x >= frame.minX && x <= frame.maxX && y >= frame.minY && y <= frame.maxY
        }?.id
    }

    /// Select the widget at `point` (nothing over empty space) and return it.
    @discardableResult
    func select(at point: CGPoint, aspect: OverlayAspect) -> OverlayWidget.ID? {
        let hit = hitTest(point, aspect: aspect)
        select(hit)
        return hit
    }

    // MARK: - Gestures

    /// Start a drag or resize: its updates are measured from the layout now,
    /// and ``endGesture()`` records the whole gesture as one step.
    func beginGesture() {
        gestureStart = layout
    }

    /// Move the selected widget by `translation` from where the gesture began,
    /// snapped to the grid and kept inside the safe area. Starts a gesture if
    /// none is in progress.
    func drag(by translation: CGSize) {
        updateSelected { start in
            // A click that doesn't move leaves the widget exactly where it is.
            guard translation != .zero else { return start.frame }
            return NormalizedRect(x: Self.snap(start.frame.x + Double(translation.width)),
                           y: Self.snap(start.frame.y + Double(translation.height)),
                           width: start.frame.width, height: start.frame.height)
        }
    }

    /// Move the selected widget's `handle` edges by `translation` from where the
    /// gesture began, as drawn in `aspect`: snapped to the grid, held inside the
    /// safe area, never below the minimum size. Starts a gesture if none is in
    /// progress.
    func resize(_ handle: OverlayResizeHandle, by translation: CGSize, aspect: OverlayAspect) {
        updateSelected { start in
            guard translation != .zero else { return start.frame }
            let drawn = start.frame.resolved(in: aspect, anchor: start.anchor)
            let moved = Self.moving(handle, of: drawn, by: translation, minimum: Self.minimumDrawnSize(in: aspect))
            let stored = NormalizedRect.reference(from: moved, in: aspect, anchor: start.anchor)
            return Self.snapped(stored, holding: handle)
        }
    }

    /// End the gesture in progress, recording it as one step if it changed the
    /// layout.
    func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if layout != start { record(start) }
    }

    /// Move the selected widget `dx`, `dy` grid steps (``largeNudgeSteps`` each
    /// with ⇧) — one arrow key, one step in the history. Returns whether the
    /// key was the editor's: `false` without a selection, and while a drag is
    /// still open (a nudge then would make the dragged widget jump).
    @discardableResult
    func nudge(dx: Int, dy: Int, large: Bool) -> Bool {
        let step = Self.gridStep * Double(large ? Self.largeNudgeSteps : 1)
        guard gestureStart == nil, let index = selectedIndex else { return false }
        commit { layout in
            let frame = layout.widgets[index].frame
            layout.widgets[index].frame = Self.placed(NormalizedRect(
                x: Self.snap(frame.x + Double(dx) * step), y: Self.snap(frame.y + Double(dy) * step),
                width: frame.width, height: frame.height))
        }
        return true
    }

    // MARK: - Internals

    private var selectedIndex: Int? {
        selection.flatMap { id in layout.widgets.firstIndex { $0.id == id } }
    }

    /// Re-place the selected widget from its rect at the gesture's start.
    private func updateSelected(_ place: (OverlayWidget) -> NormalizedRect) {
        guard let index = selectedIndex, let id = selection else { return }
        if gestureStart == nil { beginGesture() }
        guard let start = gestureStart?.widgets.first(where: { $0.id == id }) else { return }
        var edited = layout
        edited.widgets[index].frame = Self.placed(place(start))
        layout = edited
    }

    /// `value` on the grid. Computed in whole steps and divided back, so a grid
    /// value is the exact double its decimal literal is (`7 / 100 == 0.07`).
    private static func snap(_ value: Double) -> Double {
        let steps = (1 / gridStep).rounded()
        return (value * steps).rounded() / steps
    }

    /// `rect` sized to at least the minimum and moved inside the safe area.
    private static func placed(_ rect: NormalizedRect) -> NormalizedRect {
        rect.clamped(to: .safeArea(margin: OverlayLayout.safeMargin), minimumSize: OverlayLayout.minimumWidgetSize)
    }

    /// The smallest a widget is drawn in `aspect` at the stored minimum size, on
    /// each axis — what a resize drag in the preview stops at.
    private static func minimumDrawnSize(in aspect: OverlayAspect) -> CGSize {
        let drawn = NormalizedRect(x: 0.5, y: 0.5, width: OverlayLayout.minimumWidgetSize,
                                   height: OverlayLayout.minimumWidgetSize)
            .resolved(in: aspect, anchor: .topLeading, safeMargin: 0)
        return CGSize(width: drawn.width, height: drawn.height)
    }

    /// `rect` with `handle`'s edges moved by `translation`, each held inside the
    /// safe area and stopping `minimum` short of the opposite edge — so mapping
    /// it back to the reference frame never has to shift it.
    private static func moving(_ handle: OverlayResizeHandle, of rect: NormalizedRect, by translation: CGSize,
                               minimum: CGSize) -> NormalizedRect {
        let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let dx = Double(translation.width), dy = Double(translation.height)
        let minWidth = Double(minimum.width), minHeight = Double(minimum.height)
        if handle.movesLeading { minX = min(max(minX + dx, safe.minX), maxX - minWidth) }
        if handle.movesTrailing { maxX = max(min(maxX + dx, safe.maxX), minX + minWidth) }
        if handle.movesTop { minY = min(max(minY + dy, safe.minY), maxY - minHeight) }
        if handle.movesBottom { maxY = max(min(maxY + dy, safe.maxY), minY + minHeight) }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `rect` with the edges `handle` moves snapped to the grid and held inside
    /// the safe area and the minimum size; the other edges stay where they are.
    private static func snapped(_ rect: NormalizedRect, holding handle: OverlayResizeHandle) -> NormalizedRect {
        let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)
        let minimum = OverlayLayout.minimumWidgetSize
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeading { minX = min(max(snap(minX), safe.minX), maxX - minimum) }
        if handle.movesTrailing { maxX = max(min(snap(maxX), safe.maxX), minX + minimum) }
        if handle.movesTop { minY = min(max(snap(minY), safe.minY), maxY - minimum) }
        if handle.movesBottom { maxY = max(min(snap(maxY), safe.maxY), minY + minimum) }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
