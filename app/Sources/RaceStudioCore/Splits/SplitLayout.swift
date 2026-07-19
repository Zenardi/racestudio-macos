import Foundation

/// The character of a split in the Split Times report (issue 8.11): whether the
/// track piece is a corner or a straight, chosen per split so the report can be
/// read by section type.
public enum SplitKind: String, CaseIterable, Sendable, Identifiable {
    case straight
    case corner

    public var id: String { rawValue }

    /// The label the type control shows.
    public var title: String {
        switch self {
        case .straight: return "Straight"
        case .corner: return "Corner"
        }
    }
}

/// One split — a named, typed section of the lap — in the Split Times report (issue
/// 8.11): a contiguous half-open range of the lap's fine **base grid** cells, plus
/// its display name, ``SplitKind``, and whether it is locked against editing.
public struct Split: Equatable, Sendable, Identifiable {
    /// A stable id, unique within a ``SplitLayout``. It survives rename/kind/lock,
    /// but merge/divide mint fresh splits (with new ids) for their results.
    public let id: Int
    /// The user-facing name (defaults to `"S1"`, `"S2"`, …; editable).
    public var name: String
    /// Corner or straight; straight by default.
    public var kind: SplitKind
    /// Whether merge/divide leave this split — and its boundary — untouched.
    public var locked: Bool
    /// The half-open base-cell range this split spans in the lap's fine grid.
    public let range: Range<Int>

    public init(id: Int, name: String, kind: SplitKind = .straight,
                locked: Bool = false, range: Range<Int>) {
        self.id = id
        self.name = name
        self.kind = kind
        self.locked = locked
        self.range = range
    }

    /// The number of base cells the split spans.
    public var cellCount: Int { range.count }
}

/// An ordered partition of a lap's fine **base grid** `[0, base)` into editable
/// ``Split``s (issue 8.11).
///
/// The base grid is the fixed-resolution segmentation the FFI returns
/// (``SplitReportModel/baseResolution`` cells); the splits group those cells into
/// the sections the user reads. The ranges tile `[0, base)` with no gap or overlap
/// — an invariant every operation preserves — so a split's time is just the sum of
/// its base cells, and merge/divide/rename/type never re-read the session. A
/// ``Split/locked`` split (and its boundary) is left untouched by merge/divide.
///
/// The edit operations are **pure**: each returns a new, still-valid layout, so the
/// model assigns `layout = layout.merging(id)` and its tests assert on the result.
public struct SplitLayout: Equatable, Sendable {

    /// The number of base-grid cells the splits partition.
    public let base: Int
    /// The splits, in track order; their ranges tile `[0, base)`.
    public private(set) var splits: [Split]
    /// Monotonic id source so merge/divide mint ids no live split reuses. `private`,
    /// so the synthesized memberwise initializer is also private — the type is only
    /// built through ``even(base:count:)`` and the pure edit operations.
    private var nextID: Int

    /// A layout of `count` splits evenly partitioning `[0, base)` — the initial
    /// layout, and the reset a split-count change produces.
    ///
    /// `count` is clamped to `1...base` (each split owns at least one base cell); the
    /// remainder of an uneven division is spread across the leading splits so the
    /// partition is as even as possible and covers every cell. A non-positive `base`
    /// yields a single empty split, so the type is always well-formed.
    public static func even(base: Int, count: Int) -> SplitLayout {
        guard base > 0 else {
            return SplitLayout(base: 0, splits: [Split(id: 0, name: "S1", range: 0..<0)], nextID: 1)
        }
        let n = min(max(count, 1), base)
        var splits: [Split] = []
        var start = 0
        for index in 0..<n {
            let width = base / n + (index < base % n ? 1 : 0)
            splits.append(Split(id: index, name: "S\(index + 1)", range: start..<(start + width)))
            start += width
        }
        return SplitLayout(base: base, splits: splits, nextID: n)
    }

    // MARK: - Editing (pure)

    /// Merge the split with `id` into its neighbour, returning the new layout. It
    /// merges into the following split, or the preceding one when `id` is last. A
    /// no-op (an unchanged layout) when there is only one split, when `id` is
    /// unknown, or when either the split or its merge partner is ``Split/locked``.
    public func merging(_ id: Int) -> SplitLayout {
        guard splits.count > 1, let i = splits.firstIndex(where: { $0.id == id }) else { return self }
        let j = i < splits.count - 1 ? i + 1 : i - 1
        guard !splits[i].locked, !splits[j].locked else { return self }
        let lo = min(i, j), hi = max(i, j)
        // Contiguous ranges: the low split's lower bound to the high split's upper.
        let merged = Split(id: nextID, name: splits[lo].name, kind: splits[lo].kind,
                           range: splits[lo].range.lowerBound..<splits[hi].range.upperBound)
        var next = splits
        next.replaceSubrange(lo...hi, with: [merged])
        return SplitLayout(base: base, splits: next, nextID: nextID + 1)
    }

    /// Divide the split with `id` at its midpoint into two, returning the new layout.
    /// A no-op when `id` is unknown, ``Split/locked``, or spans a single base cell
    /// (nothing left to divide).
    public func dividing(_ id: Int) -> SplitLayout {
        guard let i = splits.firstIndex(where: { $0.id == id }) else { return self }
        let split = splits[i]
        guard !split.locked, split.cellCount > 1 else { return self }
        let mid = split.range.lowerBound + split.cellCount / 2
        let lower = Split(id: nextID, name: split.name, kind: split.kind,
                          range: split.range.lowerBound..<mid)
        let upper = Split(id: nextID + 1, name: split.name + " 2", kind: split.kind,
                          range: mid..<split.range.upperBound)
        var next = splits
        next.replaceSubrange(i...i, with: [lower, upper])
        return SplitLayout(base: base, splits: next, nextID: nextID + 2)
    }

    /// Rename the split with `id` (a no-op for an unknown id).
    public func renaming(_ id: Int, to name: String) -> SplitLayout {
        updating(id) { $0.name = name }
    }

    /// Set the ``SplitKind`` of the split with `id` (a no-op for an unknown id).
    public func settingKind(_ id: Int, to kind: SplitKind) -> SplitLayout {
        updating(id) { $0.kind = kind }
    }

    /// Lock or unlock the split with `id` (a no-op for an unknown id).
    public func settingLocked(_ id: Int, to locked: Bool) -> SplitLayout {
        updating(id) { $0.locked = locked }
    }

    /// The split's span as a fraction `[0, 1]` of the lap — what a double-clicked
    /// segment zooms the graph / track map to. `0...0` for a degenerate empty base.
    public func fractionWindow(for split: Split) -> ClosedRange<Double> {
        guard base > 0 else { return 0...0 }
        return Double(split.range.lowerBound) / Double(base)
            ... Double(split.range.upperBound) / Double(base)
    }

    private func updating(_ id: Int, _ transform: (inout Split) -> Void) -> SplitLayout {
        guard let i = splits.firstIndex(where: { $0.id == id }) else { return self }
        var next = splits
        transform(&next[i])
        return SplitLayout(base: base, splits: next, nextID: nextID)
    }
}
