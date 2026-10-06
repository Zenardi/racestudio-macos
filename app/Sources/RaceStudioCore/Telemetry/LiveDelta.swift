import Foundation
import os

/// Where a frame's live delta comes from (issue 9.9).
public enum DeltaSource: Equatable, Sendable {
    /// Computed from the 3.2 delta-t series against the reference lap, by how far
    /// into its lap the kart is (``LiveDelta``).
    case computed
    /// The logger's own running-delta channel (e.g. `Best Run Diff`, one of
    /// ``TelemetryChannelMap/loggerDeltaChannels``), converted to seconds.
    case logger(channel: String)
}

/// The running gap to a reference lap at any session instant (issue 9.9) — the
/// delta-bar widget's value.
///
/// For each lap the core's delta-t series (`delta_t_series(reference, lap)`, the
/// same series the 3.2 delta-t strip draws) is fetched once, lazily, and cached.
/// A read takes the session odometer at `t`, turns it into the distance covered
/// since the lap's first fix, maps that onto the reference lap's distance grid
/// by lap *fraction* — exactly how `delta_t` aligns two laps of different length
/// — and interpolates the series there. The sign is the strip's: positive =
/// slower than the reference (losing time), negative = gaining.
///
/// Immutable apart from that cache, which is guarded by a lock, so one instance
/// is safely read from the UI and an export worker at once. A read that misses
/// the cache fetches from the core synchronously on the reader's thread (readers
/// racing on the same cold lap may each fetch it — the fetch is idempotent), so
/// ``prefetch()`` it before sampling from the main actor or an exporter. The
/// provider keeps the session's data source alive for as long as the instance
/// lives, so a new reference can still be fetched. Switching the reference
/// (``referencing(_:)``) yields a new instance with an empty cache.
public final class LiveDelta: Sendable {

    /// The core's delta-t series of `lap` versus `reference` as `(distance, dt)`
    /// points on the reference lap's distance grid, or `[]` when unavailable.
    public typealias Provider = @Sendable (_ reference: LapID, _ lap: LapID) -> [DeltaSample]

    /// Per-reader search state for a sweep through the session, so consecutive
    /// reads skip the searches and the cache lock. Start each sweep from `Hints()`;
    /// hints carried over from another instance are detected and discarded.
    public struct Hints: Sendable {
        var distance = -1
        var series = -1
        /// The instance the cached curve came from — held, not just identified,
        /// so a freed instance's address can never be mistaken for a new one's.
        var owner: LiveDelta?
        var lap: LapID?
        var curve: Curve?

        public init() {}
    }

    /// One lap's delta-t series, ready to read by distance covered in the lap.
    struct Curve: Sendable {
        /// `dt` (s) against the reference grid distance (m).
        let series: TelemetrySeries
        /// The odometer reading at the lap's first fix — its distance zero.
        let startDistance: Double
        /// Reference lap length ÷ this lap's length: lap distance → grid distance.
        let scale: Double
    }

    /// The lap every other lap is compared against, or `nil` when there is none
    /// (no valid lap) — then every delta is `nil`.
    public let reference: LapID?

    private let windows: [LapID: SessionTimeSpan]
    private let distance: TelemetrySeries
    private let provider: Provider
    /// `nil` values record a lap already found to have no usable series.
    private let cache = OSAllocatedUnfairLock<[LapID: Curve?]>(initialState: [:])

    /// - Parameters:
    ///   - reference: the lap to compare against (usually the best lap).
    ///   - laps: the session's laps, for each lap's window.
    ///   - distance: the session odometer — cumulative distance (m) by time.
    ///   - provider: the core's delta-t series for a `(reference, lap)` pair.
    public convenience init(reference: LapID?, laps: [Lap], distance: TelemetrySeries,
                            provider: @escaping Provider) {
        var windows: [LapID: SessionTimeSpan] = [:]
        for lap in laps {
            if let window = LapSectorTimeline.window(of: lap) { windows[LapID(Int(lap.index))] = window }
        }
        self.init(reference: reference, windows: windows, distance: distance, provider: provider)
    }

    private init(reference: LapID?, windows: [LapID: SessionTimeSpan], distance: TelemetrySeries,
                 provider: @escaping Provider) {
        self.reference = reference
        self.windows = windows
        self.distance = distance
        self.provider = provider
    }

    /// The same laps and odometer compared against `reference` instead — a new
    /// instance whose curves are fetched afresh.
    public func referencing(_ reference: LapID?) -> LiveDelta {
        LiveDelta(reference: reference, windows: windows, distance: distance, provider: provider)
    }

    /// The live delta (seconds) at session time `t`, which lies in `lap`.
    public func delta(at t: Double, lap: LapID) -> Double? {
        var hints = Hints()
        return delta(at: t, lap: lap, hints: &hints)
    }

    /// The live delta at `t` in `lap`, reusing `hints` across a sweep.
    public func delta(at t: Double, lap: LapID, hints: inout Hints) -> Double? {
        guard let reference, let odometer = distance.value(at: t, hint: &hints.distance) else { return nil }
        if lap == reference { return 0 }
        if hints.lap != lap || hints.owner !== self {
            hints.owner = self
            hints.lap = lap
            hints.curve = curve(for: lap, reference: reference)
            hints.series = -1
        }
        guard let curve = hints.curve, let range = curve.series.timeRange else { return nil }
        let gridDistance = min(max((odometer - curve.startDistance) * curve.scale, range.lowerBound),
                               range.upperBound)
        return curve.series.value(at: gridDistance, hint: &hints.series)
    }

    /// Fetch every lap's curve now (the reference needs none), so a later sweep —
    /// the exporter's — never waits on the core.
    /// - Throws: `CancellationError` when the calling task is cancelled (checked
    ///   before each lap).
    public func prefetch() throws {
        guard let reference else { return }
        for lap in windows.keys.sorted(by: { $0.index < $1.index }) where lap != reference {
            try Task.checkCancellation()
            _ = curve(for: lap, reference: reference)
        }
    }

    /// The bytes retained: the odometer and every cached curve.
    var byteCount: Int {
        distance.byteCount + cache.withLock { $0.values.reduce(0) { $0 + ($1?.series.byteCount ?? 0) } }
    }

    // MARK: - Internals

    /// `lap`'s cached curve, fetched and built on first use. Built outside the
    /// lock so a slow fetch never blocks other readers; a race only duplicates an
    /// idempotent fetch.
    private func curve(for lap: LapID, reference: LapID) -> Curve? {
        if let cached = cache.withLock({ $0[lap] }) { return cached }
        let built = makeCurve(for: lap, reference: reference)
        cache.withLock { $0[lap] = .some(built) }
        return built
    }

    private func makeCurve(for lap: LapID, reference: LapID) -> Curve? {
        let samples = provider(reference, lap)
        guard let window = windows[lap], let referenceLength = samples.last?.distance,
              let extent = lapExtent(window) else { return nil }
        let lapLength = extent.upperBound - extent.lowerBound
        guard lapLength > 0, referenceLength > 0 else { return nil }
        let series = TelemetrySeries(times: samples.map(\.distance), values: samples.map(\.dt),
                                     maxGap: .infinity)
        return Curve(series: series, startDistance: extent.lowerBound, scale: referenceLength / lapLength)
    }

    /// The odometer readings at the lap's first and last fix inside its
    /// half-open window — the span `delta_t` integrates the lap over.
    private func lapExtent(_ window: SessionTimeSpan) -> ClosedRange<Double>? {
        let times = distance.times
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < window.start { low = mid + 1 } else { high = mid }
        }
        let first = low
        var last = first
        while last + 1 < times.count, times[last + 1] < window.end { last += 1 }
        guard first < times.count, times[first] < window.end else { return nil }
        let start = distance.values[first], end = distance.values[last]
        return start <= end ? start...end : nil
    }
}
