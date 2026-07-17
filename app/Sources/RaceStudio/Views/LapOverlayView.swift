import SwiftUI
import RaceStudioCore

/// The lap overlay comparison surface (issue 4.2): a lap picker on the left, the
/// overlaid 4.1 plot for a chosen channel, and the scrubbable delta-t strip
/// beneath it.
///
/// Thin: it owns the selection/cursor state and layout only. Trace building,
/// coloring, target selection, and delta-t all come from
/// `RaceStudioCore.LapOverlayViewModel`/`LapSelectionModel`, and the plot itself
/// is the reused ``TimeDistancePlotView`` (no new rendering code).
public struct LapOverlayView: View {
    private let laps: [OverlayLap]
    private let deltas: [DeltaPair: [DeltaSample]]
    private let channel: String

    @State private var selection: LapSelectionModel
    @State private var cursorDistance: Double?

    public init(laps: [OverlayLap], deltas: [DeltaPair: [DeltaSample]],
                channel: String, initialSelection: LapSelectionModel = LapSelectionModel()) {
        self.laps = laps
        self.deltas = deltas
        self.channel = channel
        _selection = State(initialValue: initialSelection)
    }

    public var body: some View {
        // Build the view-model once per render, not once per access.
        let overlay = LapOverlayViewModel(selection: selection, laps: laps, deltas: deltas)
        HStack(spacing: 0) {
            lapPicker(overlay)
                .frame(width: 180)
            Divider()
            VStack(spacing: 4) {
                TimeDistancePlotView(traces: overlay.traces(for: channel),
                                     mode: .distance, renderer: .swiftCharts)
                deltaStrip(overlay)
            }
        }
    }

    @ViewBuilder
    private func deltaStrip(_ overlay: LapOverlayViewModel) -> some View {
        if let reference = selection.reference, let target = selection.comparisonTarget {
            // Compute the strip once and reuse it for both the render and the readout.
            let strip = overlay.deltaStrip(reference: reference, target: target)
            DeltaStripView(
                strip: strip,
                readout: cursorDistance.flatMap {
                    overlay.readout(in: strip, at: $0, reference: reference, target: target)
                },
                cursorDistance: $cursorDistance)
        }
    }

    private func lapPicker(_ overlay: LapOverlayViewModel) -> some View {
        List(laps, id: \.id) { lap in
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(overlay.colorForLap(lap.id)))
                    .frame(width: 10, height: 10)
                Text(lap.label)
                Spacer()
                if selection.reference == lap.id {
                    Text("REF").font(.caption2).foregroundColor(.secondary)
                }
                Toggle("", isOn: binding(for: lap.id)).labelsHidden()
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.setReference(lap.id) }
        }
    }

    private func binding(for lap: LapID) -> Binding<Bool> {
        Binding(
            get: { selection.selected.contains(lap) },
            set: { _ in selection.toggle(lap) })
    }
}
