import Foundation
import Combine

/// A layout offered by the analysis window's left rail (issue 8.3): the "panel
/// set" the central host can show. The Time/Distance plot is the primary
/// layout; the 2.4 session summary is demoted to one of these.
///
/// Named `WindowLayout` to avoid colliding with the 5.4 `AnalysisLayout`
/// project-file struct — this is the *kind* of live panel shown, not the
/// persisted pane configuration.
public enum WindowLayout: String, CaseIterable, Sendable, Identifiable {
    /// The live multi-channel Time/Distance plot (issue 4.1).
    case timeDistance
    /// The 2.4 session summary (metadata + channel/lap listings).
    case summary

    public var id: String { rawValue }

    /// The rail's human-readable label.
    public var title: String {
        switch self {
        case .timeDistance: return "Time / Distance"
        case .summary: return "Summary"
        }
    }

    /// The SF Symbol name for the rail button (kept in Core so the rail view is a
    /// trivial, logic-free binding).
    public var systemImageName: String {
        switch self {
        case .timeDistance: return "chart.xyaxis.line"
        case .summary: return "list.bullet.rectangle"
        }
    }
}

/// The analysis window's side-panel selection (issue 8.3): which channels are
/// plotted and which laps are chosen. Held at the window level so it is
/// preserved when the rail swaps the active layout.
public struct AnalysisSelection: Equatable, Sendable {

    /// The selected channels, in the order the user added them — this order
    /// drives the trace and measure order.
    public private(set) var channels: [ChannelID]

    /// The selected laps, reusing the 4.2 model (and its reference-lap invariant).
    public private(set) var laps: LapSelectionModel

    public init(channels: [ChannelID] = [], laps: LapSelectionModel = LapSelectionModel()) {
        self.channels = channels
        self.laps = laps
    }

    /// Whether no channels are selected (the plot / measures bar is then empty).
    public var isEmpty: Bool { channels.isEmpty }

    /// Add `channel` if absent, remove it if present (preserving the order of the
    /// rest).
    public mutating func toggleChannel(_ channel: ChannelID) {
        if let index = channels.firstIndex(of: channel) {
            channels.remove(at: index)
        } else {
            channels.append(channel)
        }
    }

    /// Toggle `lap` in the lap selection (delegating to the 4.2 invariant).
    public mutating func toggleLap(_ lap: LapID) {
        laps.toggle(lap)
    }
}

/// One entry in the bottom measures bar (issue 8.3): a selected channel's
/// value at the shared cursor, both raw and unit-formatted.
public struct ChannelMeasure: Equatable, Sendable, Identifiable {
    public let channel: ChannelID
    /// The value-at-cursor (with the 4.4 extrapolation flag).
    public let readout: Readout
    /// The value rendered with the channel's unit + precision (em dash when absent).
    public let formatted: String

    public var id: String { channel.name }

    public init(channel: ChannelID, readout: Readout, formatted: String) {
        self.channel = channel
        self.readout = readout
        self.formatted = formatted
    }
}

/// The `@MainActor` Core state behind the analysis window shell (issue 8.3): the
/// rail's panel set + active layout, the channel/lap selection, and the window's
/// shared ``LinkedCursor`` — everything the thin `AnalysisWindowView` binds to.
///
/// It reads traces and measures for the selected channels through the 8.1
/// ``AnalysisSession`` (behind the ``SessionDataSource`` seam, so it is covered
/// FFI-free). Selecting a layout only swaps ``activeLayout``; the selection and
/// the cursor live here, so they survive the swap. Reads happen once per
/// selection change and are cached, so scrubbing the cursor re-interpolates the
/// cached samples rather than re-reading the channel each move.
///
/// `@MainActor` because it owns the (main-actor) ``AnalysisSession`` and cursor
/// and is observed by the UI on the main actor; macOS 13 has no `@Observable`,
/// so it is an `ObservableObject`.
@MainActor
public final class AnalysisWindowModel: ObservableObject {

    /// The decoded session presented by the window.
    public let session: Session

    /// The layouts the rail offers, in display order.
    public let layouts: [WindowLayout]

    /// The active layout the central host renders.
    @Published public private(set) var activeLayout: WindowLayout

    /// The channel + lap selection, preserved across layout switches.
    @Published public private(set) var selection: AnalysisSelection

    /// The channel search text for the side panel (issue 8.4); empty lists every
    /// channel.
    @Published public private(set) var channelQuery: String = ""

    /// The channel ordering for the side panel (issue 8.4).
    @Published public private(set) var channelSort: ChannelSort = .configuration

    /// The window-level shared cursor every panel links against.
    public let linkedCursor: LinkedCursor

    /// The live analysis pump, or `nil` when the loader vends no data source
    /// (the non-FFI test loaders) — then traces and measures are empty.
    private let analysis: AnalysisSession?

    /// Channel name → channel index, so a `ChannelID` selection maps back onto the
    /// index-addressed ``AnalysisSession`` reads (first occurrence wins).
    private let channelIndexByID: [ChannelID: Int]

    /// Cached read of the selected channels — rebuilt only when the selection
    /// changes — so a cursor move re-interpolates without re-reading the channels.
    private var selectionData: [SelectionEntry] = []

    private struct SelectionEntry {
        let channel: ChannelID
        let trace: ChannelTrace
        let series: ChannelSeries
        let formatter: ChannelFormatter
    }

    /// - Parameters:
    ///   - session: the decoded session (metadata/channels/laps).
    ///   - analysis: the live pump for windowed sample reads, or `nil`.
    ///   - layouts: the rail's panel set (defaults to every ``WindowLayout``).
    public init(session: Session, analysis: AnalysisSession?,
                layouts: [WindowLayout] = WindowLayout.allCases) {
        self.session = session
        self.analysis = analysis
        self.layouts = layouts
        self.activeLayout = layouts.first ?? .timeDistance

        var index: [ChannelID: Int] = [:]
        for (offset, channel) in session.channels.enumerated() {
            let id = ChannelID(channel.name)
            if index[id] == nil { index[id] = offset }
        }
        self.channelIndexByID = index

        // Default-select the first channel so the window opens on a live plot.
        var selection = AnalysisSelection()
        if let first = session.channels.first {
            selection.toggleChannel(ChannelID(first.name))
        }
        self.selection = selection

        // The cursor's basis is the session's time extent — the lap span, or the
        // selected channel's sample extent when the session has no laps. The
        // distance basis is a placeholder until real distances are wired in a
        // later issue, so the window scrubs on the time axis.
        let basis = Self.timeBasis(session: session, analysis: analysis,
                                   channelIndexByID: index, selection: selection)
        self.linkedCursor = LinkedCursor(times: basis.times, distances: basis.distances,
                                         time: basis.times.first ?? 0)

        rebuildSelectionData()
    }

    /// Convenience over the loaded ``SessionViewModel`` (issue 8.1), so the shell
    /// builds the window straight from the store's `.loaded` state.
    public convenience init(viewModel: SessionViewModel,
                            layouts: [WindowLayout] = WindowLayout.allCases) {
        self.init(session: viewModel.session, analysis: viewModel.analysis, layouts: layouts)
    }

    // MARK: - Layout rail

    /// Make `layout` the active panel (a no-op for a layout not in ``layouts``).
    /// The selection and cursor are untouched, so switching layouts preserves
    /// them.
    public func select(layout: WindowLayout) {
        guard layouts.contains(layout) else { return }
        activeLayout = layout
    }

    // MARK: - Side panel

    /// Toggle `channel` in the selection and refresh the cached traces/measures.
    public func toggleChannel(_ channel: ChannelID) {
        selection.toggleChannel(channel)
        rebuildSelectionData()
    }

    /// Toggle `lap` in the selection. Laps do not yet scope the traces (lap
    /// overlay is a later issue), so no read is needed.
    public func toggleLap(_ lap: LapID) {
        selection.toggleLap(lap)
    }

    /// Set the side panel's channel search text (issue 8.4).
    public func setChannelQuery(_ query: String) {
        channelQuery = query
    }

    /// Set the side panel's channel ordering (issue 8.4).
    public func setChannelSort(_ sort: ChannelSort) {
        channelSort = sort
    }

    /// The channels & laps side panel derived from the current session, selection,
    /// query, and sort (issue 8.4). Rebuilt on demand — a cheap pass over the
    /// channel/lap listings — so it always reflects the latest selection.
    public var sidePanel: ChannelLapSelectionModel {
        ChannelLapSelectionModel(channels: session.channels, laps: session.laps,
                                 selection: selection, query: channelQuery, sort: channelSort)
    }

    // MARK: - Central host (Time/Distance)

    /// The traces for the selected channels, in selection order — the input to
    /// the reused `TimeDistancePlotView`. Empty when there is no analysis pump.
    public var traces: [ChannelTrace] {
        selectionData.map(\.trace)
    }

    // MARK: - Measures bar

    /// The value-at-cursor for each selected channel, in selection order. Reads
    /// the shared cursor's time position and interpolates the cached samples, so
    /// it updates on every cursor move without re-reading the channels.
    public var measures: [ChannelMeasure] {
        let x = linkedCursor.timePosition
        return selectionData.map { entry in
            let readout = ValueAtCursor.value(at: x, in: entry.series)
            return ChannelMeasure(channel: entry.channel, readout: readout,
                                  formatted: entry.formatter.string(for: readout.value))
        }
    }

    // MARK: - Internals

    /// Re-read the selected channels once (trace + series + formatter), so cursor
    /// moves re-interpolate the cache rather than re-reading across the seam.
    private func rebuildSelectionData() {
        guard let analysis else { selectionData = []; return }
        selectionData = selection.channels.compactMap { id in
            guard let index = channelIndexByID[id] else { return nil }
            let trace = analysis.trace(channelIndex: index)
            let series = ChannelSeries(xs: trace.samples.map(\.time), values: trace.samples.map(\.value))
            let channel = session.channels[index]
            let formatter = ChannelFormatter(unit: channel.unit, precision: Int(channel.decimals))
            return SelectionEntry(channel: id, trace: trace, series: series, formatter: formatter)
        }
    }

    /// The session's time extent as a two-point cursor basis: the lap span
    /// `[earliest lap start, latest lap end]`, or — when the session has no laps —
    /// the first selected channel's sample-time extent, so a lapless session is
    /// still scrubbable. Empty arrays when neither is available (the cursor then
    /// has no bounds). Distances are placeholders (`0`) — the reverse distance↔time
    /// mapping and ``LinkedCursor/distancePosition`` are not meaningful until the
    /// real distance axis is wired in a later issue.
    private static func timeBasis(session: Session, analysis: AnalysisSession?,
                                  channelIndexByID: [ChannelID: Int],
                                  selection: AnalysisSelection) -> (times: [Double], distances: [Double]) {
        if let start = session.laps.map(\.startTimeS).min(),
           let end = session.laps.map(\.endTimeS).max(), start <= end {
            return (times: [start, end], distances: [0, 0])
        }
        // No laps: bound the cursor by the first selected channel's sample times.
        if let analysis, let id = selection.channels.first, let index = channelIndexByID[id] {
            let xs = analysis.series(channelIndex: index).xs
            if let first = xs.first, let last = xs.last, first <= last {
                return (times: [first, last], distances: [0, 0])
            }
        }
        return (times: [], distances: [])
    }
}
