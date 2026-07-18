import SwiftUI
import RaceStudioCore

/// The channels & laps side panel (issue 8.4): a searchable, sortable channel
/// list with per-channel colour squares + on/off toggles, and a laps table with
/// best-lap highlight, invalid-lap greying, per-lap colour, and visibility
/// toggles.
///
/// Deliberately **thin**: every bit of filter / sort / colour / best-lap / invalid
/// logic lives in `RaceStudioCore.ChannelLapSelectionModel`, rebuilt by
/// ``AnalysisWindowModel/sidePanel``. This view only renders the derived rows and
/// forwards search text, sort changes, and taps back into the shared model, so a
/// toggle updates the plot and the colour squares together.
struct ChannelsLapsPanelView: View {
    @ObservedObject var model: AnalysisWindowModel

    var body: some View {
        let panel = model.sidePanel
        VStack(spacing: 0) {
            searchAndSort
            Divider()
            List {
                Section("Channels") {
                    ForEach(panel.channelRows) { row in
                        ChannelRowView(row: row) { model.toggleChannel(row.channel) }
                    }
                }
                Section("Laps") {
                    ForEach(panel.lapRows) { row in
                        LapRowView(row: row) { model.toggleLap(row.lap) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var searchAndSort: some View {
        VStack(spacing: 8) {
            TextField("Search channels", text: Binding(
                get: { model.channelQuery },
                set: { model.setChannelQuery($0) }))
                .textFieldStyle(.roundedBorder)
            Picker("Sort", selection: Binding(
                get: { model.channelSort },
                set: { model.setChannelSort($0) })) {
                ForEach(ChannelSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(8)
    }
}

// MARK: - Rows

/// One channel row: a colour square, name, unit, and a check when plotted.
private struct ChannelRowView: View {
    let row: ChannelRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                ColorSquare(color: row.color, filled: row.isSelected)
                Text(row.name)
                Spacer()
                if !row.unit.isEmpty { Text(row.unit).foregroundColor(.secondary) }
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(row.isSelected ? .accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One lap row: a colour square, the lap number + time, a best-lap star, greyed
/// when invalid, and a visibility check.
private struct LapRowView: View {
    let row: LapRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                ColorSquare(color: row.color, filled: row.isVisible)
                Text("Lap \(row.number)")
                Text(row.isBest ? "★" : " ").foregroundColor(.yellow)
                Spacer()
                Text(row.time).font(.body.monospacedDigit()).foregroundColor(.secondary)
                Image(systemName: row.isVisible ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(row.isVisible ? .accentColor : .secondary)
            }
            .contentShape(Rectangle())
            // Invalid laps (out/in or degenerate) are greyed so the user reads
            // them as excluded from the best-lap math.
            .foregroundColor(row.isValid ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

/// The per-row colour square — filled when shown, a hollow outline when off.
private struct ColorSquare: View {
    let color: PlotColor
    let filled: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(filled ? Color(color) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(color), lineWidth: 1.5))
            .frame(width: 14, height: 14)
    }
}
