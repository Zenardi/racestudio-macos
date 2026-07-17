import Foundation

/// One point of a delta-t strip: the accumulated time gained/lost by the target
/// versus the reference at a distance along the lap (issue 4.2). Negative `dt`
/// means the target is ahead (faster) at that point.
public struct DeltaSample: Equatable, Sendable {
    public let distance: Double
    public let dt: Double

    public init(distance: Double, dt: Double) {
        self.distance = distance
        self.dt = dt
    }
}

/// A `(reference, target)` lap pair — the key under which the 3.2 delta-t series
/// is supplied to ``LapOverlayViewModel`` (issue 4.2).
public struct DeltaPair: Hashable, Sendable {
    public let reference: LapID
    public let target: LapID

    public init(reference: LapID, target: LapID) {
        self.reference = reference
        self.target = target
    }
}

/// The instantaneous delta-t readout at the cursor: the interpolated `dt` and
/// which lap is leading (ahead on time) there — `nil` when tied (issue 4.2).
public struct DeltaReadout: Equatable, Sendable {
    public let distance: Double
    public let dt: Double
    public let leader: LapID?

    public init(distance: Double, dt: Double, leader: LapID?) {
        self.distance = distance
        self.dt = dt
        self.leader = leader
    }
}

/// The distance-aligned, per-channel series for one lap (from the 3.8 resampled
/// lap data), plus a display `label` (issue 4.2).
public struct OverlayLap: Equatable, Sendable {
    public let id: LapID
    public let label: String
    public let times: [Double]
    public let distances: [Double]
    public let channels: [String: [Double]]

    public init(id: LapID, label: String, times: [Double], distances: [Double], channels: [String: [Double]]) {
        self.id = id
        self.label = label
        self.times = times
        self.distances = distances
        self.channels = channels
    }
}

/// Builds the overlay comparison surface (issue 4.2): one distance-aligned
/// ``ChannelTrace`` per selected lap with a deterministic color, plus the
/// delta-t strip and cursor readout versus the reference lap.
///
/// It **consumes** the 3.2 delta-t output (supplied per ``DeltaPair``) and the
/// 3.8 aligned lap series (``OverlayLap``); it never recomputes delta-t itself.
public struct LapOverlayViewModel: Sendable {
    public let selection: LapSelectionModel
    private let laps: [LapID: OverlayLap]
    private let deltas: [DeltaPair: [DeltaSample]]

    public init(selection: LapSelectionModel, laps: [OverlayLap], deltas: [DeltaPair: [DeltaSample]]) {
        self.selection = selection
        self.laps = Dictionary(laps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.deltas = deltas
    }

    /// One distance-aligned trace per selected lap that carries `channel`, in
    /// selection order.
    public func traces(for channel: String) -> [ChannelTrace] {
        selection.selected.compactMap { id in
            guard let lap = laps[id], let values = lap.channels[channel] else { return nil }
            return ChannelTrace(name: lap.label, times: lap.times, distances: lap.distances, values: values)
        }
    }

    /// The distinct, stable color for `lap`, assigned by its position in the
    /// selection (``PlotColor/unselected`` when not selected).
    public func colorForLap(_ lap: LapID) -> PlotColor {
        guard let index = selection.selected.firstIndex(of: lap) else { return .unselected }
        return PlotColor.palette[index % PlotColor.palette.count]
    }

    /// The delta-t strip of `target` versus `reference`: the 3.2 series for the
    /// pair, or all-zeros over the reference's distance basis when they are the
    /// same lap. Empty when neither is available.
    public func deltaStrip(reference: LapID, target: LapID) -> [DeltaSample] {
        guard selection.reference != nil else { return [] }
        if reference == target {
            guard let lap = laps[reference] else { return [] }
            return lap.distances.map { DeltaSample(distance: $0, dt: 0) }
        }
        return deltas[DeltaPair(reference: reference, target: target)] ?? []
    }

    /// The interpolated delta-t and leading lap at cursor `distance`, or `nil`
    /// when there is no strip for the pair. Negative `dt` means the target is
    /// ahead (leads); positive means the reference leads; zero is a tie.
    public func deltaAtCursor(reference: LapID, target: LapID, distance: Double) -> DeltaReadout? {
        let strip = deltaStrip(reference: reference, target: target)
        guard !strip.isEmpty else { return nil }
        let dt = interpolatedDelta(strip, at: distance)
        let leader: LapID?
        if dt < 0 {
            leader = target
        } else if dt > 0 {
            leader = reference
        } else {
            leader = nil
        }
        return DeltaReadout(distance: distance, dt: dt, leader: leader)
    }

    /// Linear interpolation of a `(distance, dt)` strip at `distance`, clamped to
    /// the endpoints (the strip is ascending in distance).
    private func interpolatedDelta(_ strip: [DeltaSample], at distance: Double) -> Double {
        guard let first = strip.first else { return 0 }
        if distance <= first.distance { return first.dt }
        for i in 1..<strip.count where distance <= strip[i].distance {
            let (a, b) = (strip[i - 1], strip[i])
            let span = b.distance - a.distance
            if span == 0 { return a.dt }
            return a.dt + (b.dt - a.dt) * (distance - a.distance) / span
        }
        return strip[strip.count - 1].dt
    }
}
