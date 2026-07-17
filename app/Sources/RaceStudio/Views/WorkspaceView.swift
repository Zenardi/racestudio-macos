import SwiftUI
import RaceStudioCore

/// The shared linked-view registry, injected through the environment so any
/// workspace tile / view-model can register to receive cursor moves (issue 4.7).
private struct LinkedViewRegistryKey: EnvironmentKey {
    static let defaultValue = LinkedViewRegistry()
}

extension EnvironmentValues {
    var linkedViewRegistry: LinkedViewRegistry {
        get { self[LinkedViewRegistryKey.self] }
        set { self[LinkedViewRegistryKey.self] = newValue }
    }
}

/// The analysis workspace (issue 4.7): tiles the M4 views and binds them to one
/// shared `WorkspaceCursor`, so the plot hover, the table values, and the other
/// tiles all track the same physical point.
///
/// Thin: the cursor's time↔distance conversion (`WorkspaceCursor`), the drag
/// selection normalization (`CursorSelection`), and the broadcast fan-out
/// (`LinkedViewRegistry`) all live in `RaceStudioCore`. This view only lays out
/// the tiles, forwards the cursor position onto each tile's axis, and injects the
/// shared cursor + registry via the environment — no sync logic of its own.
public struct WorkspaceView: View {
    @ObservedObject private var cursor: WorkspaceCursor
    @State private var selection = CursorSelection()
    @State private var registry = LinkedViewRegistry()

    private let traces: [ChannelTrace]
    private let readout: ReadoutTableModel
    private let formatters: [ChannelID: ChannelFormatter]

    public init(cursor: WorkspaceCursor,
                traces: [ChannelTrace],
                readout: ReadoutTableModel,
                formatters: [ChannelID: ChannelFormatter] = [:]) {
        _cursor = ObservedObject(wrappedValue: cursor)
        self.traces = traces
        self.readout = readout
        self.formatters = formatters
    }

    public var body: some View {
        VStack(spacing: 8) {
            cursorReadout
            TimeDistancePlotView(traces: traces, mode: .distance, renderer: .swiftCharts)
                .frame(minHeight: 200)
            // The readout table is on the distance axis, so it reads the shared
            // cursor's distancePosition (converted from the canonical time).
            ChannelTableView(model: readout, cursorX: cursor.distancePosition, formatters: formatters)
        }
        .padding(12)
        .environmentObject(cursor)
        .environment(\.linkedViewRegistry, registry)
        .accessibilityLabel("Analysis workspace")
    }

    /// A compact readout of the shared cursor and current selection.
    private var cursorReadout: some View {
        HStack(spacing: 16) {
            Text(String(format: "t = %.2f s", cursor.timePosition))
            Text(String(format: "d = %.1f m", cursor.distancePosition))
            Spacer()
            if let range = selection.range, !selection.isEmpty {
                Text(String(format: "selection %.1f–%.1f", range.lowerBound, range.upperBound))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundColor(.secondary)
    }
}
