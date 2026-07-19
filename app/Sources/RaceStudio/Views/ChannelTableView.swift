import SwiftUI
import RaceStudioCore

/// The channel table and pinned digital readouts (issues 4.4 / 8.5): a grid whose
/// rows are channels and whose columns are the selected laps, each cell showing
/// the channel's value at the cursor (greyed when extrapolated) and — when a
/// reference lap is set — the signed delta vs that lap, plus "big number"
/// readouts for a few pinned channels.
///
/// Thin: the value-at-cursor lookup, per-lap slicing, and reference deltas
/// (`ReadoutTableModel`) and the unit-aware formatting (`ChannelFormatter`) are
/// computed in `RaceStudioCore`; this view lays the results into a grid, colors
/// the extrapolated ones, and forwards pin / set-reference taps back to the model.
///
/// The pin / set-reference handlers are optional: when omitted (e.g. the read-only
/// 4.7 workspace) the channel and lap headers render as plain, non-interactive
/// labels rather than inert buttons.
public struct ChannelTableView: View {
    private let model: ReadoutTableModel
    private let cursorX: Double
    private let formatters: [ChannelID: ChannelFormatter]
    private let pinned: [ChannelID]
    private let referenceLap: LapID?
    private let onPin: ((ChannelID) -> Void)?
    private let onSetReference: ((LapID) -> Void)?

    public init(model: ReadoutTableModel, cursorX: Double,
                formatters: [ChannelID: ChannelFormatter], pinned: [ChannelID] = [],
                referenceLap: LapID? = nil,
                onPin: ((ChannelID) -> Void)? = nil,
                onSetReference: ((LapID) -> Void)? = nil) {
        self.model = model
        self.cursorX = cursorX
        self.formatters = formatters
        self.pinned = pinned
        self.referenceLap = referenceLap
        self.onPin = onPin
        self.onSetReference = onSetReference
    }

    /// One grid row: a channel and its per-lap cells (value + delta), keyed by the
    /// channel so SwiftUI diffs by identity (not position) when the list changes.
    private struct TableRow: Identifiable {
        let channel: ChannelID
        let cells: [DeltaReadoutCell]
        var id: ChannelID { channel }
    }

    public var body: some View {
        // One lookup per render; SwiftUI diffs the stable cell ids. The channel
        // list drives the row identity directly (the grid is rows × columns).
        let rows = zip(model.rows, model.deltaCells(atX: cursorX, reference: referenceLap))
            .map { TableRow(channel: $0, cells: $1) }
        VStack(alignment: .leading, spacing: 12) {
            if !pinned.isEmpty {
                pinnedReadouts(rows)
            }
            grid(rows)
        }
        .padding(8)
    }

    // MARK: - Pinned digital readouts (reference = the reference lap, else the first)

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

    /// The cell for `channel` at the reference lap (when given; otherwise the
    /// first selected lap).
    private func referenceCell(for channel: ChannelID, in rows: [TableRow]) -> ReadoutCell? {
        guard let row = rows.first(where: { $0.channel == channel }) else { return nil }
        if let referenceLap, let match = row.cells.first(where: { $0.cell.lap == referenceLap }) {
            return match.cell
        }
        return row.cells.first?.cell
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ rows: [TableRow]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(model.columns, id: \.self) { lap in
                    lapHeader(lap)
                }
            }
            ForEach(rows) { row in
                GridRow {
                    channelHeader(row.channel).gridColumnAlignment(.leading)
                    ForEach(row.cells) { cell in
                        cellView(cell)
                    }
                }
            }
        }
    }

    /// A lap column header; tapping it makes that lap the reference (highlighted).
    /// Renders as a plain label when no set-reference handler is supplied.
    @ViewBuilder
    private func lapHeader(_ lap: LapID) -> some View {
        let isReference = lap == referenceLap
        let label = Text("Lap \(lap.index + 1)")
            .font(.caption)
            .fontWeight(isReference ? .bold : .regular)
            .foregroundColor(isReference ? .accentColor : .secondary)
        if let onSetReference {
            Button { onSetReference(lap) } label: { label }
                .buttonStyle(.plain)
                .help(isReference ? "Reference lap" : "Set as reference lap")
        } else {
            label
        }
    }

    /// A channel row header; tapping it pins/unpins the channel (pin marker shown
    /// when pinned). Renders as a plain label when no pin handler is supplied.
    @ViewBuilder
    private func channelHeader(_ channel: ChannelID) -> some View {
        let label = HStack(spacing: 4) {
            if pinned.contains(channel) {
                Image(systemName: "pin.fill").font(.caption2).foregroundColor(.accentColor)
            }
            Text(channel.name)
        }
        if let onPin {
            Button { onPin(channel) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(pinned.contains(channel) ? "Unpin" : "Pin as a large readout")
        } else {
            label
        }
    }

    /// One cell: the value-at-cursor (greyed when extrapolated) and, when a
    /// reference lap is set, the signed delta vs that lap beneath it.
    private func cellView(_ cell: DeltaReadoutCell) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(format(cell.cell))
                .monospacedDigit()
                .foregroundColor(cell.cell.readout?.extrapolated == true ? .secondary : .primary)
            if let delta = formatDelta(cell.delta, for: cell.cell.channel) {
                Text(delta).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Formatting

    /// Formats a cell with its channel's formatter (falling back to the Core
    /// ``ChannelFormatter/plain`` default); a no-data cell becomes an em dash.
    private func format(_ cell: ReadoutCell) -> String {
        (formatters[cell.channel] ?? .plain).string(for: cell.readout?.value)
    }

    /// The signed delta string in the channel's units, or `nil` when absent. A
    /// delta that rounds to zero at the channel's precision shows an unsigned zero
    /// (so a `±ε` difference never renders a misleading `+0`); otherwise a `+` is
    /// prefixed for a positive delta (a negative already carries `-`).
    private func formatDelta(_ delta: Double?, for channel: ChannelID) -> String? {
        guard let delta else { return nil }
        let formatter = formatters[channel] ?? .plain
        let formatted = formatter.string(for: delta)
        if formatted == formatter.string(for: 0) { return formatted }
        return delta > 0 ? "+\(formatted)" : formatted
    }
}
