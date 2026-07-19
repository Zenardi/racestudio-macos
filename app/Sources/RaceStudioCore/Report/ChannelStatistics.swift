import Foundation

/// Which descriptive statistic the Channels Report plots and emphasises (issue
/// 8.10): the four headline stats every report cell shows, plus the interpolated
/// percentiles. The order is the order the picker lists them in.
public enum ReportStatistic: String, CaseIterable, Sendable, Identifiable {
    case minimum
    case maximum
    case average
    case median
    case percentile25
    case percentile75
    case percentile90
    case percentile95

    public var id: String { rawValue }

    /// The compact label the table header + statistic picker show.
    public var title: String {
        switch self {
        case .minimum: return "Min"
        case .maximum: return "Max"
        case .average: return "Avg"
        case .median: return "Median"
        case .percentile25: return "25%"
        case .percentile75: return "75%"
        case .percentile90: return "90%"
        case .percentile95: return "95%"
        }
    }
}

/// The per-window descriptive statistics one report cell carries (issue 8.10):
/// min/max/average/median plus the interpolated 25/75/90/95th percentiles of a
/// channel's samples inside one lap (or segment).
///
/// Pure and non-finite-safe: ``from(_:)`` drops `NaN`/`±∞` before computing, so a
/// sensor gap can never poison a statistic, and returns `nil` when nothing finite
/// remains (the report then renders a no-data cell). Percentiles use linear
/// interpolation between closest ranks (the common `numpy`-default method), so a
/// value read off the report matches what an analyst expects, and ``median`` is
/// exactly the 50th percentile.
public struct ChannelStatistics: Equatable, Sendable {
    /// Number of finite samples the statistics were computed over.
    public let count: Int
    public let minimum: Double
    public let maximum: Double
    /// The arithmetic mean.
    public let average: Double
    /// The 50th percentile.
    public let median: Double
    public let percentile25: Double
    public let percentile75: Double
    public let percentile90: Double
    public let percentile95: Double

    public init(count: Int, minimum: Double, maximum: Double, average: Double, median: Double,
                percentile25: Double, percentile75: Double, percentile90: Double, percentile95: Double) {
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.average = average
        self.median = median
        self.percentile25 = percentile25
        self.percentile75 = percentile75
        self.percentile90 = percentile90
        self.percentile95 = percentile95
    }

    /// The statistics of `values`, or `nil` when no finite value remains. Non-finite
    /// entries (`NaN`/`±∞`) are dropped first, so a gap never poisons the result.
    public static func from(_ values: [Double]) -> ChannelStatistics? {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let sum = sorted.reduce(0, +)
        return ChannelStatistics(
            count: sorted.count,
            minimum: first,
            maximum: last,
            average: sum / Double(sorted.count),
            median: percentile(50, ofSorted: sorted),
            percentile25: percentile(25, ofSorted: sorted),
            percentile75: percentile(75, ofSorted: sorted),
            percentile90: percentile(90, ofSorted: sorted),
            percentile95: percentile(95, ofSorted: sorted))
    }

    /// The `p`-th percentile (`p` in `0…100`) of the **ascending** `sorted` values,
    /// linearly interpolated between the two ranks bracketing `p/100 · (n − 1)`.
    /// `NaN` for empty input; the exact endpoints for `p = 0` / `p = 100`.
    public static func percentile(_ p: Double, ofSorted sorted: [Double]) -> Double {
        guard let first = sorted.first else { return .nan }
        guard sorted.count > 1 else { return first }
        let rank = (p.clamped(to: 0...100) / 100) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = rank - Double(lower)
        // `upper` is at most `count - 1` because rank ≤ n − 1, so both reads are safe.
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// The scalar for `statistic` — the value the table cell shows and the graph
    /// plots for the chosen statistic.
    public func value(for statistic: ReportStatistic) -> Double {
        switch statistic {
        case .minimum: return minimum
        case .maximum: return maximum
        case .average: return average
        case .median: return median
        case .percentile25: return percentile25
        case .percentile75: return percentile75
        case .percentile90: return percentile90
        case .percentile95: return percentile95
        }
    }
}
