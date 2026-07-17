import Foundation

/// Stable identifier for a lap in a session — its lap index (issue 4.2).
public struct LapID: Hashable, Sendable {
    public let index: Int
    public init(_ index: Int) { self.index = index }
}

/// Tracks the user's selected laps and the single reference lap they are
/// compared against (issue 4.2).
///
/// Maintains one invariant across every mutation: the ``reference`` is non-nil
/// **iff** ``selected`` is non-empty, and it is always one of the selected laps.
public struct LapSelectionModel: Equatable, Sendable {
    public private(set) var selected: [LapID]
    public private(set) var reference: LapID?

    /// Builds a selection, normalizing `reference` to uphold the invariant: it is
    /// kept only if it is one of `selected`, otherwise it promotes to the first
    /// selected lap (or `nil` when the selection is empty).
    public init(selected: [LapID] = [], reference: LapID? = nil) {
        self.selected = selected
        if let reference, selected.contains(reference) {
            self.reference = reference
        } else {
            self.reference = selected.first
        }
    }

    /// The first selected lap that is not the ``reference`` — the comparison
    /// target for the delta strip — or `nil` when only the reference (or
    /// nothing) is selected.
    public var comparisonTarget: LapID? {
        selected.first { $0 != reference }
    }

    /// Adds `lap` if absent, removes it if present; then restores the reference
    /// invariant (a removed reference promotes to the next selected lap).
    public mutating func toggle(_ lap: LapID) {
        if let index = selected.firstIndex(of: lap) {
            selected.remove(at: index)
        } else {
            selected.append(lap)
        }
        promoteReferenceIfNeeded()
    }

    /// Makes `lap` the reference, adding it to the selection if needed; never
    /// clears the rest of the selection.
    public mutating func setReference(_ lap: LapID) {
        if !selected.contains(lap) {
            selected.append(lap)
        }
        reference = lap
    }

    /// Ensures ``reference`` is a currently-selected lap, promoting the first
    /// selected lap (or clearing to `nil` when the selection is empty).
    public mutating func promoteReferenceIfNeeded() {
        if let reference, selected.contains(reference) { return }
        reference = selected.first
    }
}
