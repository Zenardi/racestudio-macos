import Foundation

/// A contiguous half-open histogram bin `[lower, upper)` (the last bin of a set
/// is closed so the maximum value is included) and how many samples fell in it
/// (issue 4.5).
public struct Bin: Equatable, Sendable {
    public let lower: Double
    public let upper: Double
    public let count: Int

    public init(lower: Double, upper: Double, count: Int) {
        self.lower = lower
        self.upper = upper
        self.count = count
    }
}

/// A typed error from the statistics models (issue 4.5).
public enum StatsError: Error, Equatable, Sendable {
    /// A histogram bin width must be positive and finite.
    case nonPositiveBinWidth
}

/// Bins a channel's values into a distribution (issue 4.5).
///
/// Non-finite samples (`NaN`, `±∞`) are ignored — they have no place in the
/// `[min, max]` range — so the reported counts always sum to the number of
/// *finite* input values. To restrict a histogram to a cursor/selection window,
/// slice the values before calling.
public struct Histogram {
    /// The widest sensible amount to pad a single-value distribution by so the
    /// lone bin is non-degenerate.
    private static let singleValuePad = 0.5

    /// Bins `values` into `binCount` equal-width bins spanning `[min, max]`.
    ///
    /// The counts sum to the number of finite values. When every finite value is
    /// equal (or `binCount <= 0`… returns `[]`), a single non-degenerate bin
    /// centered on the value holds them all. An empty (or all-non-finite) input
    /// returns no bins.
    public static func compute(values: [Double], binCount: Int) -> [Bin] {
        let finite = values.filter { $0.isFinite }
        guard binCount > 0, let lo = finite.min(), let hi = finite.max() else { return [] }

        guard lo < hi else {
            // All values equal: one non-degenerate bin centered on the value.
            return [Bin(lower: lo - singleValuePad, upper: lo + singleValuePad, count: finite.count)]
        }

        let width = (hi - lo) / Double(binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for value in finite {
            let index = Int(((value - lo) / width).rounded(.down))
            counts[min(max(index, 0), binCount - 1)] += 1
        }
        return (0..<binCount).map { index in
            // Pin the outer edges to [min, max] exactly (float drift can't leak
            // past the covered range) while interior edges stay shared.
            let lower = index == 0 ? lo : lo + Double(index) * width
            let upper = index == binCount - 1 ? hi : lo + Double(index + 1) * width
            return Bin(lower: lower, upper: upper, count: counts[index])
        }
    }

    /// Bins `values` into fixed-width bins whose edges are aligned to zero (every
    /// edge is an integer multiple of `binWidth`).
    ///
    /// Rejects a non-positive or non-finite `binWidth` with
    /// ``StatsError/nonPositiveBinWidth``. An empty (or all-non-finite) input
    /// succeeds with no bins; otherwise the bins span from the aligned edge at or
    /// below `min` to the aligned edge at or above `max` (always at least one).
    public static func compute(values: [Double], binWidth: Double) -> Result<[Bin], StatsError> {
        guard binWidth > 0, binWidth.isFinite else { return .failure(.nonPositiveBinWidth) }

        let finite = values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max() else { return .success([]) }

        let firstEdge = (lo / binWidth).rounded(.down) * binWidth
        let lastEdge = (hi / binWidth).rounded(.up) * binWidth
        // At least one bin, even when min == max lands exactly on an edge.
        let binCount = max(1, Int((((lastEdge - firstEdge) / binWidth)).rounded()))

        var counts = [Int](repeating: 0, count: binCount)
        for value in finite {
            let index = Int(((value - firstEdge) / binWidth).rounded(.down))
            counts[min(max(index, 0), binCount - 1)] += 1
        }
        let bins = (0..<binCount).map { index in
            Bin(lower: firstEdge + Double(index) * binWidth,
                upper: firstEdge + Double(index + 1) * binWidth,
                count: counts[index])
        }
        return .success(bins)
    }
}
