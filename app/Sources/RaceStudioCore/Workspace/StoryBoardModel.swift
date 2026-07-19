import Foundation

/// One card in the StoryBoard lap strip (issue 8.13): a selected lap shown in the
/// strip, its display label, and whether it is the reference lap the panels compare
/// against.
public struct StoryBoardCard: Equatable, Sendable, Identifiable {
    /// The lap this card stands for.
    public let lap: LapID
    /// The one-based display label, e.g. `"Lap 3"`.
    public let label: String
    /// Whether this is the reference lap (highlighted, drives the deltas).
    public let isReference: Bool

    /// Stable id (the lap index) so SwiftUI can `ForEach` / reorder the strip.
    public var id: Int { lap.index }

    public init(lap: LapID, label: String, isReference: Bool) {
        self.lap = lap
        self.label = label
        self.isReference = isReference
    }
}

/// The StoryBoard lap strip (issue 8.13): the shown (selected) laps in selection
/// order, with the reference lap marked — the reorderable, reference-markable strip
/// every panel reflects.
///
/// Purely derived from the lap ``LapSelectionModel`` and the session's laps, so the
/// view stays thin: showing/hiding a lap is a toggle, marking the reference is
/// ``AnalysisWindowModel/setReferenceLap(_:)``, and reordering is
/// ``AnalysisWindowModel/reorderSelectedLap(from:to:)``.
public struct StoryBoardModel: Equatable, Sendable {
    /// The cards, in selection order — only laps that exist in the session.
    public let cards: [StoryBoardCard]

    /// Builds the strip from the current lap `selection` and the session `laps`
    /// (used to keep only cards for laps that actually exist).
    public init(selection: LapSelectionModel, laps: [Lap]) {
        let validIndices = Set(laps.map { Int($0.index) })
        self.cards = selection.selected.compactMap { lap in
            guard validIndices.contains(lap.index) else { return nil }
            return StoryBoardCard(lap: lap, label: "Lap \(lap.index + 1)",
                                  isReference: selection.reference == lap)
        }
    }
}
