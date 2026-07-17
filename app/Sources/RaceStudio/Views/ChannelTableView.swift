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
    private let cursor: WorkspaceCursor
    private let formatters: [ChannelID: ChannelFormatter]
    private let pinned: [ChannelID]

    public init(model: ReadoutTableModel, cursor: WorkspaceCursor,
                formatters: [ChannelID: ChannelFormatter], pinned: [ChannelID] = []) {
        self.model = model
        self.cursor = cursor
        self.formatters = formatters
        self.pinned = pinned
    }

    public var body: some View {
        // One lookup per render; SwiftUI diffs the stable cell ids.
        let cells = model.cells(at: cursor)
        VStack(alignment: .leading, spacing: 12) {
            if !pinned.isEmpty {
                pinnedReadouts(cells)
            }
            grid(cells)
        }
        .padding(8)
    }

    // MARK: - Pinned digital readouts (reference = the first selected lap)

    @ViewBuilder
    private func pinnedReadouts(_ cells: [[ReadoutCell]]) -> some View {
        HStack(spacing: 20) {
            ForEach(pinned, id: \.self) { channel in
                if let cell = referenceCell(for: channel, in: cells) {
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

    private func referenceCell(for channel: ChannelID, in cells: [[ReadoutCell]]) -> ReadoutCell? {
        cells.first { $0.first?.channel == channel }?.first
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ cells: [[ReadoutCell]]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(model.columns, id: \.self) { lap in
                    Text("Lap \(lap.index + 1)").font(.caption).foregroundColor(.secondary)
                }
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.first?.channel.name ?? "")
                        .gridColumnAlignment(.leading)
                    ForEach(row) { cell in
                        Text(format(cell))
                            .monospacedDigit()
                            .foregroundColor(cell.readout?.extrapolated == true ? .secondary : .primary)
                    }
                }
            }
        }
    }

    /// Formats a cell with its channel's formatter (a missing formatter renders
    /// the value dimensionless); a no-data cell becomes an em dash.
    private func format(_ cell: ReadoutCell) -> String {
        let formatter = formatters[cell.channel] ?? ChannelFormatter(unit: "", precision: 2)
        return formatter.string(for: cell.readout?.value)
    }
}
