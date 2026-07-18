import SwiftUI
import RaceStudioCore

/// The channel table and pinned digital readouts (issue 4.4): a grid whose rows
/// are channels and whose columns are the selected laps, each cell showing the
/// channel's value at the cursor, plus "big number" readouts for a few pinned
/// channels.
///
/// Thin: the value-at-cursor lookup (`ReadoutTableModel`) and unit-aware
/// formatting (`ChannelFormatter`) are computed in `RaceStudioCore`; this view
/// only lays the results into a grid and colors the extrapolated ones.
public struct ChannelTableView: View {
    private let model: ReadoutTableModel
    private let cursorX: Double
    private let formatters: [ChannelID: ChannelFormatter]
    private let pinned: [ChannelID]
    private let referenceLap: LapID?

    public init(model: ReadoutTableModel, cursorX: Double,
                formatters: [ChannelID: ChannelFormatter], pinned: [ChannelID] = [],
                referenceLap: LapID? = nil) {
        self.model = model
        self.cursorX = cursorX
        self.formatters = formatters
        self.pinned = pinned
        self.referenceLap = referenceLap
    }

    /// One grid row: a channel and its per-lap cells, keyed by the channel so
    /// SwiftUI diffs by identity (not by position) when the channel list changes.
    private struct TableRow: Identifiable {
        let channel: ChannelID
        let cells: [ReadoutCell]
        var id: ChannelID { channel }
    }

    public var body: some View {
        // One lookup per render; SwiftUI diffs the stable cell ids.
        let rows = model.cells(atX: cursorX).map { TableRow(channel: $0.first?.channel ?? ChannelID(""), cells: $0) }
        VStack(alignment: .leading, spacing: 12) {
            if !pinned.isEmpty {
                pinnedReadouts(rows)
            }
            grid(rows)
        }
        .padding(8)
    }

    // MARK: - Pinned digital readouts (reference = the first selected lap)

    @ViewBuilder
    private func pinnedReadouts(_ rows: [TableRow]) -> some View {
        HStack(spacing: 20) {
            ForEach(pinned, id: \.self) { channel in
                if let cell = referenceCell(for: channel, in: rows) {
                    VStack(alignment: .leading) {
                        Text(channel.name).font(.caption).foregroundColor(.secondary)
                        Text(format(cell))
                            .font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .foregroundColor(cell.readout?.extrapolated == true ? .secondary : .primary)
                    }
                }
            }
        }
    }

    /// The cell for `channel` at the reference lap (the 4.2 reference, when
    /// given; otherwise the first selected lap).
    private func referenceCell(for channel: ChannelID, in rows: [TableRow]) -> ReadoutCell? {
        guard let row = rows.first(where: { $0.channel == channel }) else { return nil }
        if let referenceLap, let cell = row.cells.first(where: { $0.lap == referenceLap }) {
            return cell
        }
        return row.cells.first
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ rows: [TableRow]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(model.columns, id: \.self) { lap in
                    Text("Lap \(lap.index + 1)").font(.caption).foregroundColor(.secondary)
                }
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.channel.name).gridColumnAlignment(.leading)
                    ForEach(row.cells) { cell in
                        Text(format(cell))
                            .monospacedDigit()
                            .foregroundColor(cell.readout?.extrapolated == true ? .secondary : .primary)
                    }
                }
            }
        }
    }

    /// Formats a cell with its channel's formatter (falling back to the Core
    /// ``ChannelFormatter/plain`` default); a no-data cell becomes an em dash.
    private func format(_ cell: ReadoutCell) -> String {
        (formatters[cell.channel] ?? .plain).string(for: cell.readout?.value)
    }
}
