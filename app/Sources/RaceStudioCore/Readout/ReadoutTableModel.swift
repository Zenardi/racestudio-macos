import Foundation

/// Stable identifier for a channel — its name (issue 4.4).
public struct ChannelID: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// The shared workspace cursor position (issue 4.4; the full shared cursor is
/// 4.7). It carries the x-position and which axis that position is on; the
/// readout's per-cell series are supplied already on `axis`.
public struct WorkspaceCursor: Equatable, Sendable {
    public let x: Double
    public let axis: XAxisMode

    public init(x: Double, axis: XAxisMode = .distance) {
        self.x = x
        self.axis = axis
    }
}

/// The `(channel, lap)` key under which a cell's series is supplied (issue 4.4).
public struct CellKey: Hashable, Sendable {
    public let channel: ChannelID
    public let lap: LapID
    public init(channel: ChannelID, lap: LapID) {
        self.channel = channel
        self.lap = lap
    }
}

/// One table cell: a channel's value-at-cursor for a lap, or a "no data" cell
/// when that lap has no such channel (issue 4.4). The stable ``id`` lets SwiftUI
/// diff the grid so only changed cells re-render.
public struct ReadoutCell: Equatable, Sendable, Identifiable {
    public let channel: ChannelID
    public let lap: LapID
    /// The value-at-cursor, or `nil` when the lap has no data for this channel.
    public let readout: Readout?

    public init(channel: ChannelID, lap: LapID, readout: Readout?) {
        self.channel = channel
        self.lap = lap
        self.readout = readout
    }

    /// Stable row×column identity (channel name + lap index), unaffected by the
    /// cursor position.
    public var id: String { "\(channel.name)\u{1}\(lap.index)" }

    /// Whether the lap has data for this channel.
    public var hasData: Bool { readout != nil }
}

/// The channels × laps readout grid (issue 4.4): a row per channel, a column per
/// lap, each cell the channel's value at the cursor.
public struct ReadoutTableModel: Sendable {
    public let rows: [ChannelID]
    public let columns: [LapID]
    private let series: [CellKey: ChannelSeries]

    public init(rows: [ChannelID], columns: [LapID], series: [CellKey: ChannelSeries]) {
        self.rows = rows
        self.columns = columns
        self.series = series
    }

    /// The grid of cells at `cursor` (rows × columns). An empty channel list or
    /// lap selection yields an empty table.
    public func cells(at cursor: WorkspaceCursor) -> [[ReadoutCell]] {
        guard !rows.isEmpty, !columns.isEmpty else { return [] }
        return rows.map { channel in
            columns.map { lap in
                let readout = series[CellKey(channel: channel, lap: lap)]
                    .map { ValueAtCursor.value(at: cursor.x, in: $0) }
                return ReadoutCell(channel: channel, lap: lap, readout: readout)
            }
        }
    }
}
