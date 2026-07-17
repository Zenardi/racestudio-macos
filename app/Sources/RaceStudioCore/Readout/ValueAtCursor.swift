import Foundation

/// A channel's samples on a single x-basis (time or distance) — the minimal
/// `(x, value)` form the readout needs (issue 4.4). Extra elements past the
/// shortest array are dropped so the two stay index-aligned.
public struct ChannelSeries: Equatable, Sendable {
    public let xs: [Double]
    public let values: [Double]

    public init(xs: [Double], values: [Double]) {
        let count = min(xs.count, values.count)
        self.xs = Array(xs.prefix(count))
        self.values = Array(values.prefix(count))
    }
}

/// The value read off a channel at the cursor (issue 4.4): the interpolated
/// value (`nil` when there is no data), and whether it was clamped from beyond
/// the sampled range (extrapolated).
public struct Readout: Equatable, Sendable {
    public let value: Double?
    public let extrapolated: Bool

    public init(value: Double?, extrapolated: Bool) {
        self.value = value
        self.extrapolated = extrapolated
    }
}

/// Linearly interpolates a channel value at a cursor x-position (issue 4.4).
public enum ValueAtCursor {
    /// The value of `series` at x-position `x`: linear interpolation between the
    /// two bracketing samples, the exact value at a sample, or the clamped
    /// endpoint (flagged `extrapolated`) before the first / after the last
    /// sample. An empty series or a non-finite `x` yields no value.
    public static func value(at x: Double, in series: ChannelSeries) -> Readout {
        let xs = series.xs
        guard x.isFinite, let firstX = xs.first else { return Readout(value: nil, extrapolated: false) }

        let last = xs.count - 1
        // Before the first / after the last sample: clamp to the endpoint and
        // flag as extrapolated (an exact endpoint is not extrapolated).
        if x <= firstX { return Readout(value: series.values.first, extrapolated: x < firstX) }
        if x >= xs[last] { return Readout(value: series.values[last], extrapolated: x > xs[last]) }

        // Binary search for the first index whose x is >= the cursor.
        var low = 0, high = last
        while low < high {
            let mid = (low + high) / 2
            if xs[mid] < x { low = mid + 1 } else { high = mid }
        }
        let upper = low, lower = low - 1
        let x0 = xs[lower], x1 = xs[upper]
        if x == x1 { return Readout(value: series.values[upper], extrapolated: false) } // exact sample

        let span = x1 - x0
        let t = span == 0 ? 0 : (x - x0) / span
        let interpolated = series.values[lower] + (series.values[upper] - series.values[lower]) * t
        return Readout(value: interpolated, extrapolated: false)
    }
}
