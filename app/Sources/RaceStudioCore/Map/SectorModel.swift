import Foundation

/// Partitions a lap's distance axis into sectors and mini-sectors (issue 4.3).
public struct SectorModel: Sendable {
    /// The total lap length (the distance axis is `0...lapDistance`).
    public let lapDistance: Double

    public init(lapDistance: Double) {
        self.lapDistance = lapDistance
    }

    /// `splits` contiguous, equal-length sector ranges partitioning
    /// `0...lapDistance` with no gaps (adjacent ranges share an endpoint).
    /// Empty when `splits <= 0` or the lap has no length.
    public func boundaries(splits: Int) -> [ClosedRange<Double>] {
        equalRanges(splits)
    }

    /// `count` contiguous, equal-length mini-sector ranges partitioning the lap;
    /// the boundaries at distance 0 and lap-end appear exactly once. Pass a
    /// multiple of the sector-split count so the mini-sectors nest within (share
    /// boundaries with) the sectors.
    public func miniSectors(count: Int) -> [ClosedRange<Double>] {
        equalRanges(count)
    }

    /// The 0-based sector index containing `distance` for `splits` sectors, or
    /// `nil` when `distance` is outside `0...lapDistance` or `splits <= 0`.
    public func sectorIndex(forDistance distance: Double, splits: Int) -> Int? {
        guard splits > 0, lapDistance > 0, distance >= 0, distance <= lapDistance else { return nil }
        let step = lapDistance / Double(splits)
        // The lap-end distance belongs to the final sector, not a phantom one.
        return min(Int((distance / step).rounded(.down)), splits - 1)
    }

    /// `count` contiguous equal-length ranges partitioning `0...lapDistance`;
    /// empty for a non-positive count or a zero-length lap.
    private func equalRanges(_ count: Int) -> [ClosedRange<Double>] {
        guard count > 0, lapDistance > 0 else { return [] }
        let step = lapDistance / Double(count)
        return (0..<count).map { (Double($0) * step)...(Double($0 + 1) * step) }
    }
}
