import SwiftUI
import RaceStudioCore

/// The lap overlay comparison surface (issue 4.2): a lap picker on the left, the
/// overlaid 4.1 plot for a chosen channel, and the delta-t strip beneath it.
///
/// Thin: it owns the selection state and layout only. Trace building, coloring,
/// and delta-t all come from `RaceStudioCore.LapOverlayViewModel`, and the plot
/// itself is the reused ``TimeDistancePlotView`` (no new rendering code).
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

    private var overlay: LapOverlayViewModel {
        LapOverlayViewModel(selection: selection, laps: laps, deltas: deltas)
    }

    /// The first selected lap that is not the reference — the comparison target
    /// for the delta strip.
    private var target: LapID? {
        selection.selected.first { $0 != selection.reference }
    }

    public var body: some View {
        HStack(spacing: 0) {
            lapPicker
                .frame(width: 180)
            Divider()
            VStack(spacing: 4) {
                TimeDistancePlotView(traces: overlay.traces(for: channel),
                                     mode: .distance, renderer: .swiftCharts)
                if let reference = selection.reference, let target {
                    DeltaStripView(
                        strip: overlay.deltaStrip(reference: reference, target: target),
                        readout: cursorDistance.flatMap {
                            overlay.deltaAtCursor(reference: reference, target: target, distance: $0)
                        })
                }
            }
        }
    }

    private var lapPicker: some View {
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
