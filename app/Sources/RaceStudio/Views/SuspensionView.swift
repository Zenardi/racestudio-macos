import SwiftUI
import RaceStudioCore

/// The RS3 Suspension Analysis composite (issue 8.17): the shock channels'
/// time/distance trace, travel histogram, damper FFT, and a settings readout,
/// stacked into one scrolling view. The *arrangement* — which panels, in what
/// order — comes from Core's ``SuspensionComposition`` (unit-tested); this thin
/// view only renders each sub-panel for the window's shared channel selection, so
/// the composed panels stay in sync automatically.
struct SuspensionPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var stats: StatsPanelsModel
    @ObservedObject var spectrum: SpectrumPanelModel
    @ObservedObject var logSheet: LogSheetModel
    let analysis: AnalysisSession?

    private let composition = SuspensionComposition.standard

    var body: some View {
        if model.selection.isEmpty {
            ContentUnavailableHint(text: "Select a suspension channel to analyse")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(composition.panels) { kind in
                        section(kind)
                        Divider()
                    }
                }
            }
        }
    }

    /// One titled sub-panel section; the plot panels get a working height, the
    /// settings readout sizes to its content.
    private func section(_ kind: SuspensionPanelKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            panel(kind)
                .frame(minHeight: kind == .settings ? 0 : 220)
        }
    }

    @ViewBuilder
    private func panel(_ kind: SuspensionPanelKind) -> some View {
        switch kind {
        case .timeDistance:
            TimeDistancePlotView(traces: model.traces, mode: .time,
                                 lapBoundaries: lapTimeBoundaries(model.session.laps))
        case .histogram:
            HistogramPanel(model: model, stats: stats)
        case .spectrum:
            SpectrumPanel(model: model, spectrum: spectrum, analysis: analysis)
        case .settings:
            SuspensionSettingsReadout(logSheet: logSheet.sheet)
        }
    }
}

/// A compact read-only summary of the suspension-relevant setup drawn from the
/// log sheet (issue 8.17): chassis dimensions, weight, and final drive. Empty
/// fields are omitted; a wholly-empty sheet points the user at the Log Sheet.
private struct SuspensionSettingsReadout: View {
    let logSheet: LogSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            measurement("Wheelbase", logSheet.dimensions.wheelbaseMM, "mm")
            measurement("Front track", logSheet.dimensions.frontTrackMM, "mm")
            measurement("Rear track", logSheet.dimensions.rearTrackMM, "mm")
            measurement("Total weight", logSheet.weights.totalKg, "kg")
            if !logSheet.gearing.finalDrive.isEmpty {
                LabeledContent("Final drive", value: logSheet.gearing.finalDrive)
            }
            if isEmptyReadout {
                Text("No suspension settings recorded — add them in the Log Sheet.")
                    .foregroundColor(.secondary)
            }
        }
        .font(.callout)
        .padding(8)
    }

    private var isEmptyReadout: Bool {
        logSheet.dimensions == LogSheet.Dimensions()
            && logSheet.weights.totalKg == nil
            && logSheet.gearing.finalDrive.isEmpty
    }

    @ViewBuilder
    private func measurement(_ label: String, _ value: Double?, _ unit: String) -> some View {
        if let value {
            LabeledContent(label, value: "\(value.formatted()) \(unit)")
        }
    }
}
