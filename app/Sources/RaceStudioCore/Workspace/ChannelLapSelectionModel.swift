import Foundation

/// How the side panel orders its channel list (issue 8.4).
public enum ChannelSort: String, CaseIterable, Sendable, Identifiable {
    /// The order the channels were decoded in (configuration order).
    case configuration
    /// Ascending by channel name (case-insensitive).
    case alphabetical
    /// Grouped by physical type — the channel's unit — then by name; dimensionless
    /// channels sort last.
    case type

    public var id: String { rawValue }

    /// The segmented-control label.
    public var title: String {
        switch self {
        case .configuration: return "Configuration"
        case .alphabetical: return "Alphabetical"
        case .type: return "Type"
        }
    }
}

/// One channel row in the side panel (issue 8.4): identity + display fields, the
/// current shown-state, and the colour square.
public struct ChannelRow: Equatable, Sendable, Identifiable {
    /// Configuration index — a stable, unique row identity. Channel *names* can
    /// repeat in logger data, so the name is not a safe SwiftUI id.
    public let id: Int
    /// The selection key (the channel's name), shared with the plot/measures.
    public let channel: ChannelID
    public let name: String
    /// Physical unit, empty when dimensionless.
    public let unit: String
    /// Whether the channel is currently plotted.
    public let isSelected: Bool
    /// The colour square: the palette colour at the channel's selection position,
    /// or ``PlotColor/unselected`` when off.
    public let color: PlotColor

    public init(id: Int, channel: ChannelID, name: String, unit: String,
                isSelected: Bool, color: PlotColor) {
        self.id = id
        self.channel = channel
        self.name = name
        self.unit = unit
        self.isSelected = isSelected
        self.color = color
    }
}

/// One lap row in the side panel (issue 8.4): identity, timing, and the
/// best/invalid/visible state that drives the row's styling.
public struct LapRow: Equatable, Sendable, Identifiable {
    /// Lap index — a stable, unique row identity.
    public let id: Int
    /// The selection key.
    public let lap: LapID
    /// 1-based lap number for display.
    public let number: Int
    /// `m:ss.mmm` lap time, or the placeholder for an invalid duration.
    public let time: String
    /// Whether the lap's duration is finite and strictly positive. Invalid laps
    /// are greyed and excluded from the best-lap computation.
    public let isValid: Bool
    /// Whether this is the fastest valid lap (an invalid lap can never be best).
    public let isBest: Bool
    /// Whether the lap is shown (selected) — its overlay/plot is visible.
    public let isVisible: Bool
    /// The colour square: the palette colour at the lap's selection position, or
    /// ``PlotColor/unselected`` when hidden.
    public let color: PlotColor

    public init(id: Int, lap: LapID, number: Int, time: String,
                isValid: Bool, isBest: Bool, isVisible: Bool, color: PlotColor) {
        self.id = id
        self.lap = lap
        self.number = number
        self.time = time
        self.isValid = isValid
        self.isBest = isBest
        self.isVisible = isVisible
        self.color = color
    }
}

/// The Core presentation model behind the channels & laps side panel (issue 8.4):
/// a searchable, sortable channel list with per-channel colour squares + on/off
/// state, and a laps table with best-lap highlight, invalid-lap greying, per-lap
/// colour, and visibility state.
///
/// It is a **pure value** derived from the session's channels/laps and the shared
/// ``AnalysisSelection`` (plus the current query + sort), so all the filter / sort
/// / colour / best-lap / invalid logic is covered FFI-free and the SwiftUI
/// `ChannelsLapsPanelView` stays a thin binding. The mutable query / sort /
/// selection live in ``AnalysisWindowModel``, which rebuilds this model; toggling
/// a row mutates the shared selection, so the plot and the colour squares update
/// together.
public struct ChannelLapSelectionModel: Equatable, Sendable {

    /// The channel rows, filtered by the query and ordered by the sort.
    public let channelRows: [ChannelRow]

    /// The lap rows, in session order.
    public let lapRows: [LapRow]

    /// The fastest valid lap, or `nil` when the session has no valid lap.
    public let bestLap: LapID?

    /// - Parameters:
    ///   - channels: the session's channels, in configuration order.
    ///   - laps: the session's laps, in session order.
    ///   - selection: the shared channel/lap selection (drives colour + on-state).
    ///   - query: the channel search text (empty lists every channel).
    ///   - sort: the channel ordering.
    public init(channels: [Channel], laps: [Lap], selection: AnalysisSelection,
                query: String = "", sort: ChannelSort = .configuration) {
        self.channelRows = Self.channelRows(channels, selection: selection, query: query, sort: sort)

        let best = Self.bestLap(laps)
        self.bestLap = best
        self.lapRows = Self.lapRows(laps, selection: selection, best: best)
    }

    // MARK: - Channels

    private static func channelRows(_ channels: [Channel], selection: AnalysisSelection,
                                    query: String, sort: ChannelSort) -> [ChannelRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Keep the configuration index alongside each channel so the row id and
        // the configuration/tiebreak order survive filtering and sorting.
        let matched = channels.enumerated().filter { _, channel in
            needle.isEmpty || channel.name.lowercased().contains(needle)
        }
        return sorted(matched, by: sort).map { offset, channel in
            let id = ChannelID(channel.name)
            let selectionIndex = selection.channels.firstIndex(of: id)
            return ChannelRow(id: offset, channel: id, name: channel.name, unit: channel.unit,
                              isSelected: selectionIndex != nil,
                              color: paletteColor(at: selectionIndex))
        }
    }

    /// Order the (configuration-index, channel) pairs by `sort`, always breaking
    /// ties on the configuration index so the result is deterministic.
    private static func sorted(_ channels: [(offset: Int, element: Channel)],
                               by sort: ChannelSort) -> [(offset: Int, element: Channel)] {
        switch sort {
        case .configuration:
            return channels
        case .alphabetical:
            return channels.sorted { lhs, rhs in
                let (a, b) = (lhs.element.name.lowercased(), rhs.element.name.lowercased())
                return a == b ? lhs.offset < rhs.offset : a < b
            }
        case .type:
            // Typed channels (non-empty unit) first, then by unit, then by name;
            // dimensionless channels sort last. Case-insensitive throughout.
            return channels.sorted { lhs, rhs in
                let (lc, rc) = (lhs.element, rhs.element)
                if lc.unit.isEmpty != rc.unit.isEmpty { return rc.unit.isEmpty }
                let (lu, ru) = (lc.unit.lowercased(), rc.unit.lowercased())
                if lu != ru { return lu < ru }
                let (ln, rn) = (lc.name.lowercased(), rc.name.lowercased())
                if ln != rn { return ln < rn }
                return lhs.offset < rhs.offset
            }
        }
    }

    // MARK: - Laps

    /// The fastest valid lap — minimum duration, earliest on a tie — or `nil` when
    /// no lap is valid.
    private static func bestLap(_ laps: [Lap]) -> LapID? {
        laps.filter(isValid)
            .min { $0.durationS < $1.durationS }
            .map { LapID(Int($0.index)) }
    }

    private static func lapRows(_ laps: [Lap], selection: AnalysisSelection, best: LapID?) -> [LapRow] {
        laps.map { lap in
            let id = LapID(Int(lap.index))
            let selectionIndex = selection.laps.selected.firstIndex(of: id)
            return LapRow(id: Int(lap.index), lap: id, number: Int(lap.index) + 1,
                          time: LapTimeFormatter.string(from: lap.durationS),
                          isValid: isValid(lap), isBest: best == id,
                          isVisible: selectionIndex != nil,
                          color: paletteColor(at: selectionIndex))
        }
    }

    /// A lap is valid when its duration is finite and strictly positive; a
    /// non-positive or non-finite duration marks an out/in or degenerate lap.
    private static func isValid(_ lap: Lap) -> Bool {
        lap.durationS.isFinite && lap.durationS > 0
    }

    // MARK: - Shared

    /// The palette colour at a selection position (wrapping past the palette), or
    /// ``PlotColor/unselected`` when the item is not selected.
    private static func paletteColor(at selectionIndex: Int?) -> PlotColor {
        guard let index = selectionIndex else { return .unselected }
        return PlotColor.palette[index % PlotColor.palette.count]
    }
}
