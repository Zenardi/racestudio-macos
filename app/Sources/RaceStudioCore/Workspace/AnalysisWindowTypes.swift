import Foundation

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
    /// The 4.4 channel table / measures panel — value-at-cursor per channel × lap
    /// (issue 8.5).
    case channelTable
    /// The 4.3 GPS track map — racing line coloured by a channel, cursor marker,
    /// and sector marks (issue 8.6).
    case trackMap
    /// The 4.2 lap overlay + delta-t strip — laps overlaid on distance with the
    /// predictive gain/loss versus the reference lap (issue 8.7).
    case lapOverlay
    /// The 4.5 channel-distribution histogram — the selected channel's value
    /// distribution at a configurable bin count, coloured per lap (issue 8.9).
    case histogram
    /// The 4.5 channel-vs-channel scatter — the friction-circle G-G cloud of two
    /// channels with an optional least-squares trend line (issue 8.9).
    case scatter
    /// The RS3 Channels Report — a per-lap/segment min/max/avg/median table with a
    /// chosen-statistic-vs-lap graph and magic-wand presets (issue 8.10).
    case channelsReport
    /// The 4.6 math-channel editor + manager — author/validate an expression, add
    /// it as a channel, browse the function library (issue 8.8).
    case mathChannels
    /// The 2.4 session summary (metadata + channel/lap listings).
    case summary

    public var id: String { rawValue }

    /// The rail's human-readable label.
    public var title: String {
        switch self {
        case .timeDistance: return "Time / Distance"
        case .channelTable: return "Channels"
        case .trackMap: return "Track Map"
        case .lapOverlay: return "Lap Overlay"
        case .histogram: return "Histogram"
        case .scatter: return "Scatter"
        case .channelsReport: return "Report"
        case .mathChannels: return "Math"
        case .summary: return "Summary"
        }
    }

    /// The SF Symbol name for the rail button (kept in Core so the rail view is a
    /// trivial, logic-free binding).
    public var systemImageName: String {
        switch self {
        case .timeDistance: return "chart.xyaxis.line"
        case .channelTable: return "tablecells"
        case .trackMap: return "map"
        case .lapOverlay: return "point.3.connected.trianglepath.dotted"
        case .histogram: return "chart.bar.xaxis"
        case .scatter: return "chart.dots.scatter"
        case .channelsReport: return "chart.bar.doc.horizontal"
        case .mathChannels: return "function"
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

    /// Make `lap` the reference every measure is compared against (issue 8.5),
    /// selecting it first if needed (delegating to the 4.2 invariant).
    public mutating func setReferenceLap(_ lap: LapID) {
        laps.setReference(lap)
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

/// The session's time extent as a two-point cursor basis (issue 8.3): the lap span
/// `[earliest lap start, latest lap end]`, or — when the session has no laps — the
/// first selected channel's sample-time extent, so a lapless session is still
/// scrubbable. Empty arrays when neither is available (the cursor then has no
/// bounds). Distances are placeholders (`0`) — the reverse distance↔time mapping
/// and ``LinkedCursor/distancePosition`` are not meaningful until the real distance
/// axis is wired in a later issue.
///
/// A free function (not a method) so ``AnalysisWindowModel`` can call it from `init`
/// before `self` is fully formed, and to keep the model file focused.
@MainActor
func analysisCursorTimeBasis(session: Session, analysis: AnalysisSession?,
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
