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
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let model: MetadataPanelModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: theme.spacing.lg, verticalSpacing: theme.spacing.xs) {
            row("Vehicle", model.vehicle)
            row("Track", model.track)
            row("Driver", model.driver)
            row("Date", model.date)
        }
        .padding(theme.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.token(theme.typography.callout))
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.token(theme.typography.body))
                .foregroundStyle(theme.palette.textPrimary.color(scheme))
        }
    }
}

/// The channel list: name, unit, and formatted sample rate.
struct ChannelListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let rows: [ChannelRowModel]

    var body: some View {
        List(rows) { row in
            HStack {
                Text(row.name).foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                Text(row.unit).foregroundStyle(theme.palette.textSecondary.color(scheme))
                Text(row.rate).foregroundStyle(theme.palette.textSecondary.color(scheme))
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.token(theme.typography.body))
        }
    }
}

/// The lap list: 1-based number, `m:ss.mmm` time, and a best-lap marker.
struct LapListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let rows: [LapRowModel]

    var body: some View {
        List(rows) { row in
            HStack {
                Text("Lap \(row.number)")
                    .font(.token(theme.typography.body))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                Text(row.time)
                    .font(.token(theme.typography.readout))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                // The best lap is marked in the brand `positive` colour, matching the
                // "Best" marker on the library preview pane.
                Text(row.isBest ? "★" : " ").foregroundStyle(theme.palette.positive.color(scheme))
            }
        }
    }
}
