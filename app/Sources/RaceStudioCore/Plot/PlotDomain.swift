import Foundation

extension Comparable {
    /// This value clamped into `limits`. `limits` must be a valid range
    /// (`lowerBound <= upperBound`, which `ClosedRange` guarantees).
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// The plottable domain of a set of channel values or an x-basis (issue 4.1):
/// the `[min, max]` over the **finite** entries, so a stray `NaN`/`±∞` (e.g. a
/// leading sensor gap or a `0/0` math channel from the analysis layer) can never
/// produce an inverted or non-finite range that would trap `ClosedRange` or
/// corrupt the downstream `LinearScale`/`PlotViewport` math.
///
/// - A flat set (all equal) is padded by `0.5` so the axis has a non-zero span.
/// - An empty set, or one with no finite entries, falls back to `0...1`.
public func plotDomain(of values: [Double]) -> ClosedRange<Double> {
    var low = Double.infinity
    var high = -Double.infinity
    for value in values where value.isFinite {
        if value < low { low = value }
        if value > high { high = value }
    }
    guard low.isFinite, high.isFinite else { return 0...1 }
    guard low < high else { return (low - 0.5)...(low + 0.5) }
    return low...high
}
