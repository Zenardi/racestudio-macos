import SwiftUI
import RaceStudioCore

// MARK: - Split Times panel (issue 8.11)

/// Hosts the RS3 **Split Times** report: each lap divided into N splits, the time
/// spent in each shown lap after lap, the auto-computed best theoretical (sum of
/// each split's fastest time) and best rolling lap, and split editing
/// (merge / divide / rename / type / lock) in the attached ``SplitDetailsPanel``.
/// Double-clicking a split cell focuses it, zooming the section bar graph to it.
///
/// Deliberately thin: the base-grid grouping, the best-lap derivations, and the
/// split editing all live in `RaceStudioCore` (``SplitReportModel`` /
/// ``SplitReport``); this view fetches the per-lap base grid once from the live
/// ``AnalysisSession`` and lays out the table, graph, and summary.
struct SplitTimesPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var report: SplitReportModel
    let analysis: AnalysisSession?

    /// The whole-session base grid (all laps), read once per base resolution — the
    /// report filters it to the shown laps and groups it by the current layout.
    @State private var allSegments: [LapSegments] = []
    @State private var loadedBase: Int?

    var body: some View {
        let built = report.report(from: shownSegments)
        Group {
            if built.isEmpty {
                ContentUnavailableHint(text: "No laps to build the split report")
            } else {
                VSplitView {
                    VStack(spacing: 0) {
                        controls(built)
                        Divider()
                        tableView(built)
                        Divider()
                        graphView(built)
                    }
                    SplitDetailsPanel(report: report, built: built)
                }
            }
        }
        .onAppear { loadSegments() }
        .onChange(of: report.layout.base) { _ in loadSegments() }
    }

    // MARK: Data

    /// Read the whole-session base grid once for the current base resolution (it is
    /// constant for the session, so a re-render never re-marshals it across the FFI).
    private func loadSegments() {
        guard loadedBase != report.layout.base else { return }
        allSegments = analysis?.segmentTimes(splits: report.layout.base) ?? []
        loadedBase = report.layout.base
    }

    /// The shown laps' base grids: the selected laps, or — when none are selected —
    /// every session lap, so the report is populated by default.
    private var shownSegments: [LapSegments] {
        let laps = reportLaps
        guard !laps.isEmpty else { return [] }
        let ids = Set(laps.map { LapID(Int($0.index)) })
        return allSegments.filter { ids.contains($0.lap) }
    }

    private var reportLaps: [Lap] {
        let selected = model.selection.laps.selected
        guard !selected.isEmpty else { return model.session.laps }
        let ids = Set(selected)
        return model.session.laps.filter { ids.contains(LapID(Int($0.index))) }
    }

    // MARK: Controls + summary

    private func controls(_ built: SplitReport) -> some View {
        HStack(spacing: 16) {
            Stepper("Splits: \(report.splitCount)", value: Binding(
                get: { report.splitCount }, set: { report.setSplitCount($0) }),
                    in: SplitReportModel.splitCountRange)
                .fixedSize()
            Divider().frame(height: 18)
            summaryLabel("Best theoretical", built.bestTheoretical.total)
            summaryLabel("Best rolling", built.bestRolling.total)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func summaryLabel(_ title: String, _ seconds: Double) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(Self.time(seconds)).font(.caption.monospacedDigit().bold())
        }
        .help("\(title): \(Self.time(seconds))")
    }

    // MARK: Table (laps × splits)

    /// The laps × splits grid: a header of split names, a row per lap of per-split
    /// times (the lap total trailing), and a best-of-all row (each split's fastest
    /// time). The focused split column is tinted; double-clicking a cell focuses it.
    private func tableView(_ built: SplitReport) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Lap").font(.caption2.bold()).foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(built.splits) { split in
                        Text(split.name).font(.caption2.bold())
                            .foregroundColor(split.id == report.focusedSplit ? .accentColor : .secondary)
                    }
                    Text("Lap").font(.caption2.bold()).foregroundColor(.secondary)
                }
                Divider()
                ForEach(built.rows) { row in
                    GridRow {
                        Text("Lap \(row.lap.index + 1)").font(.caption)
                            .gridColumnAlignment(.leading)
                        ForEach(Array(zip(built.splits, row.times)), id: \.0.id) { split, time in
                            cell(time, split: split)
                        }
                        Text(Self.time(row.total)).font(.caption.monospacedDigit().bold())
                    }
                }
                Divider()
                bestRow(built)
            }
            .padding(8)
        }
    }

    private func cell(_ time: Double, split: Split) -> some View {
        Text(Self.time(time))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(split.id == report.focusedSplit ? Color.accentColor.opacity(0.15) : .clear)
            .cornerRadius(4)
            .onTapGesture(count: 2) { report.focus(split.id) }
            .help("Double-click to zoom to \(split.name)")
    }

    /// The "Best" row: each split's fastest time across the shown laps (the best
    /// theoretical lap's components), with the theoretical total trailing.
    private func bestRow(_ built: SplitReport) -> some View {
        GridRow {
            Text("Best").font(.caption.bold()).foregroundColor(.accentColor)
                .gridColumnAlignment(.leading)
            ForEach(built.bestTheoretical.perSplit) { best in
                Text(Self.time(best.time)).font(.caption.monospacedDigit())
                    .foregroundColor(.accentColor)
                    .help(best.lap.map { "Lap \($0.index + 1)" } ?? "—")
            }
            Text(Self.time(built.bestTheoretical.total))
                .font(.caption.monospacedDigit().bold()).foregroundColor(.accentColor)
        }
    }

    // MARK: Graph (section bars)

    /// A bar per split sized by its best time — the section profile of the lap — with
    /// the focused split highlighted and its zoom window (a fraction of the lap) named,
    /// the hook the graph / track map zoom to on a double-click.
    private func graphView(_ built: SplitReport) -> some View {
        let maxTime = max(built.bestTheoretical.perSplit.map(\.time).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Section times").font(.caption.bold())
                if let window = report.focusWindow, let split = focusedSplit(built) {
                    Text("· \(split.name) \(Self.percent(window))")
                        .font(.caption.monospacedDigit()).foregroundColor(.accentColor)
                }
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(built.bestTheoretical.perSplit) { best in
                    Rectangle()
                        .fill(best.splitID == report.focusedSplit ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(height: CGFloat(best.time / maxTime) * 80 + 2)
                        .onTapGesture(count: 2) { report.focus(best.splitID) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(minHeight: 120)
    }

    private func focusedSplit(_ built: SplitReport) -> Split? {
        built.splits.first { $0.id == report.focusedSplit }
    }

    // MARK: Formatting

    /// Seconds as `s.mmm` (three decimals) — the split-time resolution.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        return String(format: "%.3f", seconds)
    }

    /// A `[lo, hi]` lap fraction as a percent range (`25–50%`) — the zoom target.
    static func percent(_ window: ClosedRange<Double>) -> String {
        "\(Int((window.lowerBound * 100).rounded()))–\(Int((window.upperBound * 100).rounded()))%"
    }
}
