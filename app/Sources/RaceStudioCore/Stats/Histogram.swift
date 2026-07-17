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
    /// The requested width would produce an unreasonable number of bins (a wide
    /// range over a tiny width) — refused rather than trapping / exhausting memory.
    case excessiveBinCount
}

/// Bins a channel's values into a distribution (issue 4.5).
///
/// Non-finite samples (`NaN`, `±∞`) are ignored — they have no place in the
/// `[min, max]` range — so the reported counts always sum to the number of
/// *finite* input values. To restrict a histogram to a cursor/selection window,
/// slice the values before calling.
public struct Histogram {
    /// Ceiling on the number of bins either overload will produce, guarding the
    /// counts-array allocation and the `Double → Int` conversion against extreme
    /// inputs. A million bins already exceeds any sane display.
    private static let maxBins = 1_000_000
    /// The minimum half-width used to pad a single-value distribution so the lone
    /// bin is non-degenerate.
    private static let singleValuePad = 0.5
    /// A magnitude-relative floor on that pad, so the bin stays non-degenerate
    /// even for very large values where `singleValuePad` is lost to precision.
    private static let relativePad = 1e-9

    /// Bins `values` into `binCount` equal-width bins spanning `[min, max]`.
    ///
    /// The counts sum to the number of finite values. When every finite value is
    /// equal, a single non-degenerate bin centered on the value holds them all.
    /// An empty (or all-non-finite) input, a non-positive `binCount`, or a
    /// `binCount` beyond ``maxBins`` returns no bins.
    public static func compute(values: [Double], binCount: Int) -> [Bin] {
        let finite = values.filter { $0.isFinite }
        guard binCount > 0, binCount <= maxBins,
              let lo = finite.min(), let hi = finite.max() else { return [] }

        guard lo < hi else {
            // All values equal: one non-degenerate bin centered on the value.
            let pad = max(singleValuePad, abs(lo) * relativePad)
            return [Bin(lower: lo - pad, upper: lo + pad, count: finite.count)]
        }

        let width = (hi - lo) / Double(binCount)
        return bins(finite: finite, origin: lo, width: width, binCount: binCount, lastUpper: hi)
    }

    /// Bins `values` into fixed-width bins whose edges are aligned to zero (every
    /// edge is an integer multiple of `binWidth`).
    ///
    /// Rejects a non-positive or non-finite `binWidth` with
    /// ``StatsError/nonPositiveBinWidth``, and a width so small (relative to the
    /// range) that it would produce more than ``maxBins`` bins with
    /// ``StatsError/excessiveBinCount``. An empty (or all-non-finite) input
    /// succeeds with no bins; otherwise the bins span from the aligned edge at or
    /// below `min` to the aligned edge at or above `max` (always at least one).
    public static func compute(values: [Double], binWidth: Double) -> Result<[Bin], StatsError> {
        guard binWidth > 0, binWidth.isFinite else { return .failure(.nonPositiveBinWidth) }

        let finite = values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max() else { return .success([]) }

        let firstEdge = (lo / binWidth).rounded(.down) * binWidth
        let lastEdge = (hi / binWidth).rounded(.up) * binWidth
        let span = (lastEdge - firstEdge) / binWidth
        // A wide range over a tiny width overflows the Int conversion / balloons
        // the counts array; refuse it rather than trap.
        guard span.isFinite, span <= Double(maxBins) else { return .failure(.excessiveBinCount) }

        // At least one bin, even when min == max lands exactly on an edge.
        let count = max(1, Int(span.rounded()))
        return .success(bins(finite: finite, origin: firstEdge, width: binWidth,
                             binCount: count, lastUpper: firstEdge + Double(count) * binWidth))
    }

    /// Assigns each finite value to its bin and materializes the `[Bin]` (shared
    /// by both overloads so the binning rule can never diverge). `origin`/`width`
    /// define the bin grid; `lastUpper` pins the final bin's upper edge (`max`
    /// for the equal-count grid, the aligned edge for the fixed-width grid).
    private static func bins(finite: [Double], origin: Double, width: Double,
                             binCount: Int, lastUpper: Double) -> [Bin] {
        let lastIndex = binCount - 1
        var counts = [Int](repeating: 0, count: binCount)
        for value in finite {
            let ratio = (value - origin) / width
            // Guard the Double→Int conversion: extreme (but finite) inputs can
            // overflow the span so `ratio` is non-finite — pin those to the top
            // bin rather than trapping `Int(_:)`. A finite ratio is bounded by
            // `binCount` (≤ maxBins), so the conversion is always in range.
            if ratio.isFinite {
                counts[Int(ratio.rounded(.down)).clamped(to: 0...lastIndex)] += 1
            } else {
                counts[lastIndex] += 1
            }
        }
        return (0..<binCount).map { index in
            // Pin the outer edges (min/max or the aligned edges) exactly so float
            // drift can't leak past the covered range; interior edges stay shared.
            let lower = index == 0 ? origin : origin + Double(index) * width
            let upper = index == lastIndex ? lastUpper : origin + Double(index + 1) * width
            return Bin(lower: lower, upper: upper, count: counts[index])
        }
    }
}
