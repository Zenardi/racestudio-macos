import Foundation

/// The UI state for the analysis window's **Split Times** report (issue 8.11): how
/// many splits the lap's fine base grid is grouped into, the editable
/// ``SplitLayout`` (merge / divide / rename / type / lock), and which split is
/// focused for a zoom. Held apart from ``AnalysisWindowModel`` (like
/// ``StatsPanelsModel`` / ``ChannelsReportModel``) so its knobs survive layout
/// switches.
///
/// It owns no session data: ``report(from:)`` takes the window's already-read
/// ``LapSegments`` (the FFI base grid) and assembles the table + best
/// theoretical / rolling laps purely, so all of the grouping and the derivations
/// are covered here without the FFI. `@MainActor` because the SwiftUI panel reads
/// it on the main actor (macOS 13 has no `@Observable`).
@MainActor
public final class SplitReportModel: ObservableObject {

    /// The fine base-grid resolution the FFI cuts each lap into; the splits group
    /// these cells, so a split can be divided down to a single base cell.
    public static let baseResolution = 24

    /// The split counts the report offers (the base grid bounds the ceiling).
    public static let splitCountRange = 2...12

    /// How many splits the base grid is grouped into; changing it rebuilds the
    /// layout as an even partition, discarding manual edits.
    @Published public private(set) var splitCount: Int = 3

    /// The editable split layout over the base grid.
    @Published public private(set) var layout: SplitLayout

    /// The split double-clicked to zoom the graph / track map to it, or `nil`.
    @Published public private(set) var focusedSplit: Int?

    public init() {
        layout = SplitLayout.even(base: Self.baseResolution, count: 3)
    }

    // MARK: - Controls

    /// Set how many splits the base grid is grouped into, clamped to
    /// ``splitCountRange``. This rebuilds the layout as an even partition (clearing
    /// manual edits and the focus), since the split boundaries all move.
    public func setSplitCount(_ count: Int) {
        splitCount = count.clamped(to: Self.splitCountRange)
        layout = SplitLayout.even(base: Self.baseResolution, count: splitCount)
        focusedSplit = nil
    }

    /// Merge the split with `id` into its neighbour (issue 8.11).
    public func merge(_ id: Int) {
        layout = layout.merging(id)
        clampFocus()
    }

    /// Divide the split with `id` at its midpoint (issue 8.11).
    public func divide(_ id: Int) {
        layout = layout.dividing(id)
        clampFocus()
    }

    /// Rename the split with `id`.
    public func rename(_ id: Int, to name: String) {
        layout = layout.renaming(id, to: name)
    }

    /// Set the ``SplitKind`` (corner / straight) of the split with `id`.
    public func setKind(_ id: Int, to kind: SplitKind) {
        layout = layout.settingKind(id, to: kind)
    }

    /// Lock or unlock the split with `id` (a locked split resists merge / divide).
    public func setLocked(_ id: Int, _ locked: Bool) {
        layout = layout.settingLocked(id, to: locked)
    }

    /// Flip the lock on the split with `id` (a no-op for an unknown id).
    public func toggleLock(_ id: Int) {
        guard let split = layout.splits.first(where: { $0.id == id }) else { return }
        layout = layout.settingLocked(id, to: !split.locked)
    }

    /// Focus the split the user double-clicked (to zoom); passing the focused id
    /// again — or an unknown id / `nil` — clears the focus.
    public func focus(_ id: Int?) {
        guard let id, id != focusedSplit, layout.splits.contains(where: { $0.id == id }) else {
            focusedSplit = nil
            return
        }
        focusedSplit = id
    }

    // MARK: - Report

    /// The assembled report for `segments` under the current layout (issue 8.11) —
    /// pure, so the panel derives the table + best laps each render without touching
    /// the model's published state.
    public func report(from segments: [LapSegments]) -> SplitReport {
        SplitReport.make(from: segments, layout: layout)
    }

    /// The fraction-of-lap window `[0, 1]` for the focused split, or `nil` when none
    /// is focused — what the panel zooms the graph / track map to.
    public var focusWindow: ClosedRange<Double>? {
        guard let focusedSplit, let split = layout.splits.first(where: { $0.id == focusedSplit }) else {
            return nil
        }
        return layout.fractionWindow(for: split)
    }

    /// Drop the focus when the focused split no longer exists (after a merge/divide
    /// mints fresh ids).
    private func clampFocus() {
        if let focusedSplit, !layout.splits.contains(where: { $0.id == focusedSplit }) {
            self.focusedSplit = nil
        }
    }
}
