import SwiftUI
import RaceStudioCore

// MARK: - Histogram panel (issue 8.9)

/// Hosts the reused ``HistogramView`` for the first selected channel's value
/// distribution: a bin-count stepper sets the resolution, and — when laps are
/// selected — the panel shows one colour-keyed histogram per lap (small multiples)
/// so distributions are comparable across laps. The binning + per-lap colouring is
/// derived in `RaceStudioCore.StatsPanelsModel`; this view only lays out bars +
/// controls, reading the channel traces off the window model.
struct HistogramPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var stats: StatsPanelsModel

    var body: some View {
        let panel = stats.histogramPanel(traces: model.traces, laps: model.session.laps,
                                         selectedLaps: model.selection.laps.selected)
        if panel.channel.isEmpty {
            ContentUnavailableHint(text: "Select a channel to see its distribution")
        } else {
            VStack(spacing: 0) {
                controls(panel)
                Divider()
                if panel.perLap.isEmpty {
                    HistogramView(bins: panel.overall)
                } else {
                    perLap(panel)
                }
            }
        }
    }

    /// The channel title + a bin-count stepper (criterion 1: a configurable bin count).
    private func controls(_ panel: HistogramPanelModel) -> some View {
        HStack(spacing: 16) {
            Text(panel.channel).font(.caption.bold())
            Stepper("Bins: \(stats.binCount)", value: Binding(
                get: { stats.binCount },
                set: { stats.setBinCount($0) }),
                    in: StatsPanelsModel.binCountRange)
                .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// One colour-keyed histogram per selected lap (criterion 3), stacked as small
    /// multiples with a swatch + label so each lap's distribution reads on its own.
    private func perLap(_ panel: HistogramPanelModel) -> some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(panel.perLap, id: \.id) { lap in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(lap.color)).frame(width: 9, height: 9)
                            Text(lap.label).font(.caption)
                        }
                        HistogramView(bins: lap.bins, barColor: lap.color)
                            .frame(minHeight: 120)
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Scatter (G-G) panel (issue 8.9)

/// Hosts the reused ``ScatterView`` for the friction-circle G-G cloud of two
/// selected channels: axis pickers choose which channels map to x / y (default: the
/// first two selected), and a toggle shows / hides the least-squares trend line
/// (its R² read out alongside). The pairing + regression are derived in
/// `RaceStudioCore.StatsPanelsModel`; this view only maps points to pixels.
struct ScatterPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var stats: StatsPanelsModel

    var body: some View {
        let panel = stats.scatterPanel(traces: model.traces)
        if panel.yChannel.isEmpty {
            ContentUnavailableHint(text: "Select two channels to plot one against the other")
        } else {
            VStack(spacing: 0) {
                controls(panel)
                Divider()
                ScatterView(points: panel.points, fit: panel.fit)
            }
        }
    }

    /// Axis pickers (x vs y) over the selected channels + a trend-line toggle and R².
    private func controls(_ panel: ScatterPanelModel) -> some View {
        HStack(spacing: 16) {
            axisPicker("X", selection: panel.xChannel) { stats.setXChannel($0) }
            axisPicker("Y", selection: panel.yChannel) { stats.setYChannel($0) }
            Toggle("Trend line", isOn: Binding(
                get: { stats.regression },
                set: { stats.setRegression($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
            Spacer()
            if let fit = panel.fit {
                Text(String(format: "R² = %.3f", fit.r2))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// A menu picker over the selected channels for one axis.
    private func axisPicker(_ label: String, selection: String,
                            onSelect: @escaping (String) -> Void) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: { onSelect($0) })) {
            ForEach(model.selection.channels, id: \.self) { channel in
                Text(channel.name).tag(channel.name)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}
