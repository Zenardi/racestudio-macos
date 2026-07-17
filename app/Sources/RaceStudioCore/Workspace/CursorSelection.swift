import Foundation

/// A drag selection over the workspace's shared x-axis (issue 4.7): an ordered
/// `[start, end]` range that normalizes reversed drags and reports emptiness for
/// a zero-width selection.
public struct CursorSelection: Equatable, Sendable {

    /// The selected range, or `nil` when nothing is selected.
    public private(set) var range: ClosedRange<Double>?

    public init() {}

    /// Set the selection from a drag between `from` and `to`, normalizing the
    /// order so `range.lowerBound <= range.upperBound`. A non-finite endpoint is
    /// ignored (it can never form a valid range).
    public mutating func set(from: Double, to: Double) {
        guard from.isFinite, to.isFinite else { return }
        range = Swift.min(from, to)...Swift.max(from, to)
    }

    /// Whether the selection is empty: nothing selected, or a zero-width range.
    public var isEmpty: Bool {
        guard let range else { return true }
        return range.lowerBound == range.upperBound
    }

    /// Clear the selection.
    public mutating func clear() {
        range = nil
    }
}
