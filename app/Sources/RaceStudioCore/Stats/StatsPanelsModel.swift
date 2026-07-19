import Foundation

/// The UI state + assembly for the analysis window's histogram and scatter (G-G)
/// panels (issue 8.9), held apart from ``AnalysisWindowModel`` so each panel's knobs
/// (bin count, trend-line toggle, scatter axes) survive layout switches without
/// growing the window model.
///
/// It owns no channel data: the builders take the window's already-read
/// ``ChannelTrace``s (its public `traces`) and the session laps, so all of the
/// binning / pairing / colouring is covered here without the FFI, while the pure
/// ``HistogramPanelModel`` / ``ScatterPanelModel`` do the maths. `@MainActor`
/// because the SwiftUI panels read it on the main actor (macOS 13 has no
/// `@Observable`).
@MainActor
public final class StatsPanelsModel: ObservableObject {

    /// The bin counts the histogram accepts: at least one bin, up to a display
    /// ceiling beyond which bars are too thin to read.
    public static let binCountRange = 1...200

    /// The histogram bin count (issue 8.9), clamped to ``binCountRange``.
    @Published public private(set) var binCount: Int = HistogramPanelModel.defaultBinCount

    /// Whether the scatter panel fits a least-squares trend line; on by default.
    @Published public private(set) var regression: Bool = true

    /// The channels chosen for the scatter axes, or `nil` to follow the first two
    /// available channels. Resolved against the current channels at build time, so a
    /// stale name simply falls back rather than needing an explicit cleanup.
    @Published public private(set) var xChannelOverride: String?
    @Published public private(set) var yChannelOverride: String?

    public init() {}

    // MARK: - Controls

    /// Set the histogram bin count, clamped to ``binCountRange``.
    public func setBinCount(_ count: Int) {
        binCount = count.clamped(to: Self.binCountRange)
    }

    /// Turn the scatter trend line on or off.
    public func setRegression(_ enabled: Bool) {
        regression = enabled
    }

    /// Choose the scatter x-axis channel (a `nil`/empty name clears the override).
    public func setXChannel(_ channel: String?) {
        xChannelOverride = channel.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Choose the scatter y-axis channel (a `nil`/empty name clears the override).
    public func setYChannel(_ channel: String?) {
        yChannelOverride = channel.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Histogram panel

    /// The channel-distribution histogram for the first of `traces`: the whole-window
    /// bars at ``binCount`` plus one per-selected-lap distribution, coloured in
    /// selection order on a shared value grid. Empty when `traces` is empty.
    ///
    /// - Parameters:
    ///   - traces: the window's selected-channel traces, in selection order.
    ///   - laps: the session laps (any order) the selected ids resolve against.
    ///   - selectedLaps: the selected lap ids, in the order that drives per-lap colour.
    public func histogramPanel(traces: [ChannelTrace], laps: [Lap],
                               selectedLaps: [LapID]) -> HistogramPanelModel {
        guard let trace = traces.first else {
            return HistogramPanelModel(channel: "", values: [], binCount: binCount)
        }
        let series = Self.series(from: trace)
        let byIndex = Dictionary(laps.map { (Int($0.index), $0) }, uniquingKeysWith: { first, _ in first })
        let lapValues = selectedLaps.compactMap { id -> LapValues? in
            guard let lap = byIndex[id.index] else { return nil }
            let slice = series.windowed(from: lap.startTimeS, through: lap.endTimeS)
            return LapValues(id: id, label: "Lap \(lap.index + 1)", values: slice.values)
        }
        return HistogramPanelModel(channel: trace.name, values: series.values,
                                   laps: lapValues, binCount: binCount)
    }

    // MARK: - Scatter (G-G) panel

    /// The channel-vs-channel scatter (G-G) cloud for the two axis channels of
    /// `traces`, with the trend line when ``regression`` is on. Empty until two
    /// channels are available.
    public func scatterPanel(traces: [ChannelTrace]) -> ScatterPanelModel {
        let names = traces.map(\.name)
        guard let xName = resolvedXChannel(names), let yName = resolvedYChannel(names),
              let xTrace = traces.first(where: { $0.name == xName }),
              let yTrace = traces.first(where: { $0.name == yName }) else {
            return ScatterPanelModel(xChannel: "", yChannel: "",
                                     x: ChannelSeries(xs: [], values: []),
                                     y: ChannelSeries(xs: [], values: []), regression: regression)
        }
        return ScatterPanelModel(xChannel: xName, yChannel: yName,
                                 x: Self.series(from: xTrace), y: Self.series(from: yTrace),
                                 regression: regression)
    }

    /// The resolved scatter x-axis channel: the override while it is still available,
    /// else the first channel. `nil` when none are available.
    public func resolvedXChannel(_ names: [String]) -> String? {
        if let override = xChannelOverride, names.contains(override) { return override }
        return names.first
    }

    /// The resolved scatter y-axis channel: the override while it is available and not
    /// the x-axis, else the first channel that is not the x-axis. `nil` when fewer
    /// than two channels are available.
    public func resolvedYChannel(_ names: [String]) -> String? {
        let xName = resolvedXChannel(names)
        if let override = yChannelOverride, names.contains(override), override != xName {
            return override
        }
        return names.first { $0 != xName }
    }

    /// A time-basis ``ChannelSeries`` from a trace's samples (the shared
    /// ``ChannelTrace/timeSeries`` conversion).
    private static func series(from trace: ChannelTrace) -> ChannelSeries {
        trace.timeSeries
    }
}
