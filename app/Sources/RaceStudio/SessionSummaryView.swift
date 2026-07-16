import SwiftUI
import RaceStudioCore

/// The session summary screen (issue 2.4): a metadata panel above a channel list
/// and a lap list. Every string is pre-formatted by
/// `RaceStudioCore.SessionSummaryViewModel`, so these views are trivial
/// bindings and hold no logic (excluded from the coverage metric).
struct SessionSummaryView: View {
    let viewModel: SessionSummaryViewModel

    var body: some View {
        VStack(spacing: 0) {
            MetadataPanelView(model: viewModel.metadata)
            Divider()
            HStack(spacing: 0) {
                ChannelListView(rows: viewModel.channels)
                Divider()
                LapListView(rows: viewModel.laps)
            }
        }
    }
}

/// Vehicle / track / driver / date, each already em-dash-filled by the view-model.
struct MetadataPanelView: View {
    let model: MetadataPanelModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { Text("Vehicle").fieldLabel(); Text(model.vehicle) }
            GridRow { Text("Track").fieldLabel(); Text(model.track) }
            GridRow { Text("Driver").fieldLabel(); Text(model.driver) }
            GridRow { Text("Date").fieldLabel(); Text(model.date) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The channel list: name, unit, and formatted sample rate.
struct ChannelListView: View {
    let rows: [ChannelRowModel]

    var body: some View {
        List(rows) { row in
            HStack {
                Text(row.name)
                Spacer()
                Text(row.unit).foregroundColor(.secondary)
                Text(row.rate).foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
            }
        }
    }
}

/// The lap list: 1-based number, `m:ss.mmm` time, and a best-lap marker.
struct LapListView: View {
    let rows: [LapRowModel]

    var body: some View {
        List(rows) { row in
            HStack {
                Text("Lap \(row.number)")
                Spacer()
                Text(row.time).monospacedDigit()
                Text(row.isBest ? "★" : " ").foregroundColor(.yellow)
            }
        }
    }
}

private extension Text {
    /// Secondary, fixed-width label styling shared by the metadata rows.
    func fieldLabel() -> some View {
        self.foregroundColor(.secondary).frame(width: 64, alignment: .leading)
    }
}
