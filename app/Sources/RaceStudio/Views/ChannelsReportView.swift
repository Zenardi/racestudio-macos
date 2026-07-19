import SwiftUI
import RaceStudioCore

// MARK: - Channels Report panel (issue 8.10)

/// Hosts the RS3 **Channels Report**: a per-lap (or per-segment) min/max/avg/median
/// table for the selected channels, and a graph of the chosen statistic vs lap
/// number hot-tracked to the selected table row. A "magic wand" menu applies
/// vehicle-health / racer / vehicle-performance presets (channel set + statistic).
///
/// Deliberately thin: the stat assembly, the graph mapping, and the presets are all
/// derived in `RaceStudioCore.ChannelsReportModel`; this view only lays out the
/// table + graph and forwards taps. Rows drive the graph; tapping a cell hot-tracks
/// its point.
struct ChannelsReportPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var report: ChannelsReportModel

    var body: some View {
        let table = report.table(traces: model.traces, laps: reportLaps)
        if table.isEmpty {
            ContentUnavailableHint(text: "Select channels (and laps) to build the report")
        } else {
            let graph = report.graph(from: table)
            VStack(spacing: 0) {
                controls
                Divider()
                VSplitView {
                    tableView(table)
                    graphView(graph)
                }
            }
        }
    }

    /// The laps the report shows: the selected laps, or — when none are selected —
    /// every session lap, so the report is populated by default.
    private var reportLaps: [Lap] {
        let selected = model.selection.laps.selected
        guard !selected.isEmpty else { return model.session.laps }
        let ids = Set(selected)
        return model.session.laps.filter { ids.contains(LapID(Int($0.index))) }
    }

    // MARK: Controls

    /// The magic-wand preset menu, the statistic picker, and the per-lap/segment
    /// mode picker (with a segment-count stepper in per-segment mode).
    private var controls: some View {
        HStack(spacing: 16) {
            presetMenu
            Picker("Statistic", selection: Binding(
                get: { report.statistic }, set: { report.setStatistic($0) })) {
                ForEach(ReportStatistic.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            Picker("Mode", selection: Binding(
                get: { report.mode }, set: { report.setMode($0) })) {
                ForEach(ReportMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            if report.mode == .perSegment {
                Stepper("Segments: \(report.segmentCount)", value: Binding(
                    get: { report.segmentCount }, set: { report.setSegmentCount($0) }),
                        in: ChannelsReportModel.segmentCountRange)
                    .fixedSize()
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// The "magic wand" menu: one button per preset, applying its channel set to the
    /// window selection and its default statistic to the report.
    private var presetMenu: some View {
        Menu {
            ForEach(ReportPreset.allCases) { preset in
                Button(preset.title) { apply(preset) }
            }
        } label: {
            Label("Presets", systemImage: "wand.and.stars")
        }
        .fixedSize()
    }

    /// Apply `preset`: select its relevant channels (when any match) and adopt its
    /// default statistic. The selection is reconciled through the existing
    /// ``AnalysisWindowModel/toggleChannel(_:)`` — deselect what the preset drops,
    /// then select what it adds — so the report shares the window's channel set.
    private func apply(_ preset: ReportPreset) {
        let want = preset.matchingChannels(in: model.session.channels.map(\.name))
        if !want.isEmpty {
            let current = model.selection.channels
            for id in current where !want.contains(id) { model.toggleChannel(id) }
            for id in want where !current.contains(id) { model.toggleChannel(id) }
        }
        report.applyPreset(preset)
    }

    // MARK: Table

    /// The channels × columns grid: a header of interval labels, then a row per
    /// channel showing each cell's min/max/avg/median (the chosen statistic bold).
    private func tableView(_ table: ReportTable) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Channel").font(.caption2.bold()).foregroundColor(.secondary)
                    ForEach(table.columns) { column in
                        Text(column.label).font(.caption2.bold()).foregroundColor(.secondary)
                    }
                }
                Divider()
                ForEach(table.rows) { row in
                    GridRow {
                        rowHeader(row.channel, in: table)
                        ForEach(row.cells) { cell in cellView(cell, statistic: table.statistic) }
                    }
                }
            }
            .padding(8)
        }
    }

    /// A channel name button that selects the row the graph plots (bold when active).
    private func rowHeader(_ channel: ChannelID, in table: ReportTable) -> some View {
        let isActive = report.resolvedSelectedRow(table.rows.map(\.channel)) == channel
        return Button { report.selectRow(channel) } label: {
            Text(channel.name)
                .font(.caption.weight(isActive ? .bold : .regular))
                .foregroundColor(isActive ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help("Plot this channel on the graph")
    }

    /// One cell: the chosen statistic prominent, with min/max/avg/median beneath.
    /// Tapping hot-tracks the cell's column on the graph.
    @ViewBuilder
    private func cellView(_ cell: ReportCell, statistic: ReportStatistic) -> some View {
        if let stats = cell.statistics {
            Button { report.highlightColumn(cell.column) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(format(stats.value(for: statistic)))
                        .font(.caption.monospacedDigit().bold())
                    Text("min \(format(stats.minimum))  max \(format(stats.maximum))")
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    Text("avg \(format(stats.average))  med \(format(stats.median))")
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                }
                .padding(4)
                .background(isHighlighted(cell.column) ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
        } else {
            Text("—").foregroundColor(.secondary)
        }
    }

    private func isHighlighted(_ column: String) -> Bool {
        report.highlightedColumn == column
    }

    // MARK: Graph

    /// The chosen statistic plotted vs lap number for the selected channel row,
    /// reusing the line plot; a caption names the hot-tracked point.
    @ViewBuilder
    private func graphView(_ graph: ReportGraph) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if let channel = graph.channel {
                    Text("\(channel.name) · \(graph.statistic.title) vs lap")
                        .font(.caption.bold())
                }
                if let point = graph.highlighted {
                    Text("• \(point.label): \(format(point.value))")
                        .font(.caption.monospacedDigit()).foregroundColor(.accentColor)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            if graph.points.isEmpty {
                ContentUnavailableHint(text: "No values to plot for this statistic")
            } else {
                TimeDistancePlotView(traces: [graphTrace(graph)], mode: .time, renderer: .swiftCharts)
            }
        }
        .frame(minHeight: 160)
        .padding(.bottom, 8)
    }

    /// A single-channel trace of the graph's points (x = lap number, y = statistic),
    /// so the reused line plot draws the stat-vs-lap curve.
    private func graphTrace(_ graph: ReportGraph) -> ChannelTrace {
        let name = graph.channel.map { "\($0.name) \(graph.statistic.title)" } ?? graph.statistic.title
        let xs = graph.points.map(\.x)
        return ChannelTrace(name: name, times: xs,
                            distances: Array(repeating: 0, count: xs.count),
                            values: graph.points.map(\.value))
    }

    /// A compact numeric format (up to two decimals, trailing zeros trimmed).
    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }
}
