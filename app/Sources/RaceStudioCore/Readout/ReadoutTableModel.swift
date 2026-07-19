import Foundation

/// Stable identifier for a channel — its name (issue 4.4).
public struct ChannelID: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
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

    /// Stable row×column identity, unaffected by the cursor position (reuses the
    /// composite ``CellKey`` rather than a stringly-typed key).
    public var id: CellKey { CellKey(channel: channel, lap: lap) }

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
        // Deduplicate (keeping first occurrence) so the grid never has two cells
        // with the same identity — which would break SwiftUI's ForEach diffing.
        var seenRows = Set<ChannelID>()
        var seenColumns = Set<LapID>()
        self.rows = rows.filter { seenRows.insert($0).inserted }
        self.columns = columns.filter { seenColumns.insert($0).inserted }
        self.series = series
    }

    /// The grid of cells at cursor x-position `x` on the series' axis (rows ×
    /// columns). An empty channel list or lap selection yields an empty table.
    /// The shared 4.7 ``WorkspaceCursor`` supplies `x` as its `timePosition` or
    /// `distancePosition` for whichever axis the readout series are on.
    public func cells(atX x: Double) -> [[ReadoutCell]] {
        guard !rows.isEmpty, !columns.isEmpty else { return [] }
        return rows.map { channel in
            columns.map { lap in
                let readout = series[CellKey(channel: channel, lap: lap)]
                    .map { ValueAtCursor.value(at: x, in: $0) }
                return ReadoutCell(channel: channel, lap: lap, readout: readout)
            }
        }
    }

    /// The grid at cursor `x` with each cell's signed delta vs the `reference`
    /// lap's value for the same channel (issue 8.5): one interpolation pass, so
    /// the shape and cell identities match ``cells(atX:)``.
    public func deltaCells(atX x: Double, reference: LapID?) -> [[DeltaReadoutCell]] {
        // The reference lap sits at one fixed column for every row, so resolve its
        // position once rather than re-scanning each row for it.
        let referenceColumn = reference.flatMap { columns.firstIndex(of: $0) }
        return cells(atX: x).map { row in
            let baseline = referenceColumn.flatMap { row[$0].readout?.value }
            return row.map { cell in
                DeltaReadoutCell(cell: cell, delta: Self.delta(of: cell, vs: baseline, reference: reference))
            }
        }
    }

    /// `cell.value − baseline`, or `nil` when there is no reference, the cell *is*
    /// the reference column, or either side is absent / non-finite.
    private static func delta(of cell: ReadoutCell, vs baseline: Double?, reference: LapID?) -> Double? {
        guard let reference, cell.lap != reference,
              let value = cell.readout?.value, value.isFinite,
              let baseline, baseline.isFinite else { return nil }
        return value - baseline
    }
}

/// One readout cell plus its delta vs the reference lap (issue 8.5): the measures
/// panel renders the value and, when a reference lap is set, the signed delta
/// beneath it. Wraps ``ReadoutCell`` so its stable ``id`` still drives SwiftUI
/// diffing.
public struct DeltaReadoutCell: Equatable, Sendable, Identifiable {
    /// The underlying value-at-cursor cell.
    public let cell: ReadoutCell
    /// `cell` value minus the reference lap's value for the same channel; `nil`
    /// when no reference is set, this is the reference column, or either value is
    /// missing / non-finite.
    public let delta: Double?

    public init(cell: ReadoutCell, delta: Double?) {
        self.cell = cell
        self.delta = delta
    }

    /// The wrapped cell's stable row×column identity.
    public var id: CellKey { cell.id }
}
