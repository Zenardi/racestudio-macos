import Foundation

/// Which quantity the plot's x-axis represents (issue 4.1).
public enum XAxisMode: String, CaseIterable, Sendable {
    case time
    case distance
}

/// One plotted point: a channel value tagged with both an elapsed `time` and a
/// cumulative `distance`, so the x-axis can switch between the two with no data
/// loss. Both bases come pre-resampled from the analysis layer (issue 3.8).
public struct PlotSample: Equatable, Sendable {
    public let time: Double
    public let distance: Double
    public let value: Double

    /// Creates a sample tagged with both x-bases and its channel value.
    public init(time: Double, distance: Double, value: Double) {
        self.time = time
        self.distance = distance
        self.value = value
    }
}

/// A single channel's trace: a name and its ordered ``PlotSample``s, with the
/// x-basis (time or distance) chosen at read time.
public struct ChannelTrace: Equatable, Sendable, Identifiable {
    public let name: String
    public let samples: [PlotSample]
    public var id: String { name }

    /// Creates a trace from a name and its ordered samples.
    public init(name: String, samples: [PlotSample]) {
        self.name = name
        self.samples = samples
    }

    /// Builds a trace from parallel arrays. Elements past the shortest array are
    /// dropped so the three stay index-aligned (upstream 3.8 arrays are equal
    /// length; this is a defensive guard, never a trap).
    public init(name: String, times: [Double], distances: [Double], values: [Double]) {
        let count = min(times.count, min(distances.count, values.count))
        var samples: [PlotSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            samples.append(PlotSample(time: times[i], distance: distances[i], value: values[i]))
        }
        self.init(name: name, samples: samples)
    }

    /// The x-basis for `mode`: the per-sample time or distance.
    public func xValues(mode: XAxisMode) -> [Double] {
        switch mode {
        case .time: return samples.map(\.time)
        case .distance: return samples.map(\.distance)
        }
    }

    /// The x-value of the sample at `index` for `mode`, or `.nan` when `index`
    /// is out of range.
    public func x(at index: Int, mode: XAxisMode) -> Double {
        guard samples.indices.contains(index) else { return .nan }
        let sample = samples[index]
        return mode == .time ? sample.time : sample.distance
    }

    /// The index of the sample nearest x-position `x` for `mode`, or `nil` when
    /// the trace is empty. Convenience over ``hitTest(x:in:)``; callers on the
    /// hot path should cache ``xValues(mode:)`` rather than rebuild it per call.
    public func hitTest(x: Double, mode: XAxisMode) -> Int? {
        // Route through the shared helper: the free `hitTest(x:in:)` is shadowed
        // by this method inside the type, so name it explicitly.
        nearestSortedIndex(to: x, in: xValues(mode: mode))
    }
}

/// The min/max of a channel over one pixel column, with the sample indices that
/// produced them — the unit of the min/max decimation shared by the Metal
/// renderer and the Swift Charts fallback (issue 4.1).
public struct ColumnExtent: Equatable, Sendable {
    public let min: Double
    public let max: Double
    public let minIndex: Int
    public let maxIndex: Int

    /// Creates a column extent from its min/max values and their sample indices.
    public init(min: Double, max: Double, minIndex: Int, maxIndex: Int) {
        self.min = min
        self.max = max
        self.minIndex = minIndex
        self.maxIndex = maxIndex
    }
}

/// Returns the index of the entry in the ascending `xs` nearest to `x`, ties
/// resolved to the lower index; `nil` when `xs` is empty (issue 4.1).
///
/// `xs` must be sorted ascending (time and cumulative distance both are); the
/// nearest neighbour is found by binary search, so this stays cheap on the
/// dense series the cursor probes.
public func hitTest(x: Double, in xs: [Double]) -> Int? {
    nearestSortedIndex(to: x, in: xs)
}

/// Shared nearest-neighbour search behind ``hitTest(x:in:)`` and
/// ``ChannelTrace/hitTest(x:mode:)`` (which cannot name the shadowed global).
private func nearestSortedIndex(to x: Double, in xs: [Double]) -> Int? {
    guard !xs.isEmpty else { return nil }
    let last = xs.count - 1
    if x <= xs[0] { return 0 }
    if x >= xs[last] { return last }

    // First index whose value is >= x.
    var low = 0, high = last
    while low < high {
        let mid = (low + high) / 2
        if xs[mid] < x { low = mid + 1 } else { high = mid }
    }
    let upperIndex = low, lowerIndex = low - 1
    let distanceToLower = x - xs[lowerIndex]
    let distanceToUpper = xs[upperIndex] - x
    // Ties resolve to the lower index.
    return distanceToLower <= distanceToUpper ? lowerIndex : upperIndex
}

/// A single point of a plotted polyline, in domain coordinates (issue 4.1).
public struct PlotPoint: Identifiable, Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// Builds the polyline a renderer draws for `trace` on the `mode` x-basis,
/// restricted to the `visible` x-window and decimated to at most `columns`
/// min/max pairs (issue 4.1, ADR 0003).
///
/// Only the samples inside `visible` are considered (found by binary search, so
/// zooming in reveals the detail within the window rather than a coarser whole-
/// trace envelope). When that slice is denser than `columns` it is reduced to
/// per-column min/max pairs via ``envelope(values:columns:)``, emitted in sample
/// order so the line stays monotonic in x; otherwise the raw slice is returned.
/// Both render paths call this, so they draw the identical shape.
public func plotPolyline(
    trace: ChannelTrace,
    mode: XAxisMode,
    visible: ClosedRange<Double>,
    columns: Int
) -> [PlotPoint] {
    let allX = trace.xValues(mode: mode)
    guard !allX.isEmpty else { return [] }

    // [start, end) = the samples whose x lies inside `visible` (allX ascending).
    let start = sortedLowerBound(allX, visible.lowerBound)
    let end = sortedUpperBound(allX, visible.upperBound)
    guard start < end else { return [] }

    let xs = Array(allX[start..<end])
    let values = trace.samples[start..<end].map(\.value)

    guard columns > 0, values.count > columns else {
        return xs.indices.map { PlotPoint(id: $0, x: xs[$0], y: values[$0]) }
    }

    var points: [PlotPoint] = []
    points.reserveCapacity(columns * 2)
    var id = 0
    for extent in envelope(values: values, columns: columns) {
        let lower = min(extent.minIndex, extent.maxIndex)
        let upper = max(extent.minIndex, extent.maxIndex)
        points.append(PlotPoint(id: id, x: xs[lower], y: values[lower]))
        id += 1
        if upper != lower {
            points.append(PlotPoint(id: id, x: xs[upper], y: values[upper]))
            id += 1
        }
    }
    return points
}

/// First index of ascending `xs` whose value is `>= target` (the count if none).
/// Module-internal so the readout path (4.4) reuses one binary search.
func sortedLowerBound(_ xs: [Double], _ target: Double) -> Int {
    var low = 0, high = xs.count
    while low < high {
        let mid = (low + high) / 2
        if xs[mid] < target { low = mid + 1 } else { high = mid }
    }
    return low
}

/// First index of ascending `xs` whose value is `> target` (the count if none).
private func sortedUpperBound(_ xs: [Double], _ target: Double) -> Int {
    var low = 0, high = xs.count
    while low < high {
        let mid = (low + high) / 2
        if xs[mid] <= target { low = mid + 1 } else { high = mid }
    }
    return low
}

/// Buckets `values` into `columns` evenly-sized index ranges and returns each
/// bucket's min/max with the indices that produced them — the visible envelope
/// both render paths draw, guaranteeing pixel-identical output (issue 4.1).
///
/// The column count is clamped to `values.count`, so every returned bucket is
/// non-empty. Returns `[]` for empty input or a non-positive `columns`.
public func envelope(values: [Double], columns: Int) -> [ColumnExtent] {
    guard columns > 0, !values.isEmpty else { return [] }
    let n = values.count
    let columnCount = min(columns, n)
    var result: [ColumnExtent] = []
    result.reserveCapacity(columnCount)
    for column in 0..<columnCount {
        let start = column * n / columnCount
        let end = (column + 1) * n / columnCount // exclusive; > start since columnCount <= n
        var minValue = values[start], maxValue = values[start]
        var minIndex = start, maxIndex = start
        var i = start + 1
        while i < end {
            let value = values[i]
            if value < minValue { minValue = value; minIndex = i }
            if value > maxValue { maxValue = value; maxIndex = i }
            i += 1
        }
        result.append(ColumnExtent(min: minValue, max: maxValue, minIndex: minIndex, maxIndex: maxIndex))
    }
    return result
}
