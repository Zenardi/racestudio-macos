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
    /// The 2.4 session summary (metadata + channel/lap listings).
    case summary

    public var id: String { rawValue }

    /// The rail's human-readable label.
    public var title: String {
        switch self {
        case .timeDistance: return "Time / Distance"
        case .channelTable: return "Channels"
        case .trackMap: return "Track Map"
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
