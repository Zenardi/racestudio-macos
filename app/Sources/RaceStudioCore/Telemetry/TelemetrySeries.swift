import Foundation

/// How a ``TelemetrySeries`` is read between two of its samples (issue 9.9).
public enum InterpolationMode: Equatable, Sendable {
    /// The straight line between the two bracketing samples — every continuous
    /// channel (speed, rpm, G, temperatures, pedals).
    case linear
    /// The earlier sample's value, held until the next sample arrives — a
    /// discrete channel such as gear, which must never read "3.5".
    case stepHold
}

/// One channel's samples on the session clock, laid out as two contiguous
/// arrays and read at any session time `t` (issue 9.9).
///
/// It is the building block of ``TelemetryTimeline``: the exporter reads 30–60
/// frames a second for every role, so a read must be cheap. ``value(at:)`` is a
/// binary search (O(log n)); ``value(at:hint:)`` carries the last bracket
/// between calls so a monotone sweep is amortized O(1), and gives exactly the
/// same answer for any `t` (the hint only shortens the search).
///
/// A read is `nil` — never a fabricated or clamped value — when `t` is not
/// finite, lies before the first or after the last sample, lies inside a gap
/// longer than ``maxGap``, or lands on/next to a non-finite sample.
public struct TelemetrySeries: Equatable, Sendable {

    /// The gap threshold (seconds) used when none is given: two samples further
    /// apart than this have missing data between them.
    public static let defaultMaxGap = 0.5

    /// Sample times (seconds, session clock), strictly increasing.
    public let times: [Double]
    /// Sample values, index-aligned with ``times``.
    public let values: [Double]
    /// How the series is read between two samples.
    public let mode: InterpolationMode
    /// The longest span (seconds) between two samples that is still bridged;
    /// a longer one reads `nil` strictly inside it.
    public let maxGap: Double

    /// - Parameters:
    ///   - times: sample times in seconds. Samples a search cannot use are
    ///     dropped (``searchableIndices(_:count:)``): a non-finite time, one that
    ///     does not move strictly forward (a repeat, or an out-of-order record the
    ///     decoder leaves as logged), and a lone forward spike.
    ///   - values: sample values; extra elements past the shorter array are dropped.
    ///   - mode: linear (default) or step-hold.
    ///   - maxGap: the gap threshold, ``defaultMaxGap`` by default.
    public init(times: [Double], values: [Double], mode: InterpolationMode = .linear,
                maxGap: Double = TelemetrySeries.defaultMaxGap) {
        let count = Swift.min(times.count, values.count)
        if count == times.count, count == values.count, Self.isSearchable(times) {
            // Already clean: keep the caller's buffers (no copy), so sibling
            // series built from one time array share its storage.
            self.times = times
            self.values = values
        } else {
            let kept = Self.searchableIndices(times, count: count)
            self.times = kept.map { times[$0] }
            self.values = kept.map { values[$0] }
        }
        self.mode = mode
        self.maxGap = maxGap
    }

    /// The gap threshold for samples `sampleInterval` seconds apart: two
    /// periods, never under ``defaultMaxGap`` — so a slow channel's normal
    /// cadence (1 Hz logger temperature, a 1 Hz GPS) is not mistaken for a gap.
    /// An unknown (non-positive or non-finite) interval gets the default.
    public static func gapThreshold(sampleInterval: Double) -> Double {
        guard sampleInterval > 0, sampleInterval.isFinite else { return defaultMaxGap }
        return Swift.max(defaultMaxGap, 2 * sampleInterval)
    }

    /// The gap threshold for samples at `times`, from their median spacing.
    public static func gapThreshold(forTimes times: [Double]) -> Double {
        var steps: [Double] = []
        steps.reserveCapacity(times.count)
        for index in times.indices.dropFirst() where times[index] > times[index - 1] {
            steps.append(times[index] - times[index - 1])
        }
        steps.sort()
        return gapThreshold(sampleInterval: steps.isEmpty ? 0 : steps[steps.count / 2])
    }

    /// The indices of the first `count` of `times` a search can use, in order:
    /// finite and strictly increasing. A time that steps back (or repeats) is
    /// dropped — the earlier record is trusted, as the decoder treats a single
    /// out-of-order record. A lone forward spike — later than both of the next
    /// two samples, which themselves continue the series — is dropped on its
    /// own, instead of hiding every sample until the clock catches up with it.
    static func searchableIndices(_ times: [Double], count: Int) -> [Int] {
        var kept: [Int] = []
        kept.reserveCapacity(count)
        var last = -Double.infinity
        for index in 0..<count where times[index].isFinite && times[index] > last {
            let time = times[index]
            if index + 2 < count, times[index + 1] > last, time > times[index + 1], time > times[index + 2] {
                continue
            }
            kept.append(index)
            last = time
        }
        return kept
    }

    /// Whether the series has no samples.
    public var isEmpty: Bool { times.isEmpty }

    /// The span from the first to the last sample, or `nil` when empty.
    public var timeRange: ClosedRange<Double>? {
        guard let first = times.first, let last = times.last else { return nil }
        return first...last
    }

    /// The value at session time `t` — the random-access read (binary search).
    public func value(at t: Double) -> Double? {
        var hint = -1
        return value(at: t, hint: &hint)
    }

    /// The value at session time `t`, reusing `hint` — the index of the sample
    /// that opened the bracket last time — to skip the search when the reads
    /// move forward. Any hint (stale, negative, out of range) is safe: it is only
    /// trusted when it still brackets `t`, and is updated for the next call.
    public func value(at t: Double, hint: inout Int) -> Double? {
        guard let lower = bracket(at: t, hint: &hint) else { return nil }
        let t0 = times[lower]
        if t == t0 { return finite(values[lower]) }
        // `bracket` only returns the last index for `t` exactly on it, so an
        // upper neighbour exists here.
        let upper = lower + 1
        let t1 = times[upper]
        guard t1 - t0 <= maxGap else { return nil }
        switch mode {
        case .stepHold:
            return finite(values[lower])
        case .linear:
            let v0 = values[lower], v1 = values[upper]
            return finite(v0 + (v1 - v0) * (t - t0) / (t1 - t0))
        }
    }

    // MARK: - Internals

    /// The index of the last sample at or before `t` (the shared hinted search),
    /// or `nil` when `t` is not finite or lies outside `[first, last]`.
    private func bracket(at t: Double, hint: inout Int) -> Int? {
        guard t.isFinite, let last = times.last, t <= last else { return nil }
        let index = lastIndex(atOrBefore: t, in: times, hint: &hint)
        return index >= 0 ? index : nil
    }

    private func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    /// Strictly increasing and finite throughout.
    private static func isSearchable(_ times: [Double]) -> Bool {
        var previous = -Double.infinity
        for time in times {
            guard time.isFinite, time > previous else { return false }
            previous = time
        }
        return true
    }
}
