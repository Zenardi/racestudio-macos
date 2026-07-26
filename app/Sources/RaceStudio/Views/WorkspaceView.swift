import SwiftUI
import RaceStudioCore

/// The shared linked-view registry, injected through the environment so an
/// imperative workspace consumer (e.g. a view-model or the Metal renderer) can
/// register to receive cursor moves (issue 4.7). The default is `nil` — absence
/// is explicit, so tiles never fall back to a shared process-wide instance that
/// would cross-link separate workspaces.
private struct LinkedViewRegistryKey: EnvironmentKey {
    static let defaultValue: LinkedViewRegistry? = nil
}

extension EnvironmentValues {
    var linkedViewRegistry: LinkedViewRegistry? {
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
///
/// SwiftUI tiles link simply by observing the shared cursor; the injected
/// registry is the explicit-callback path for imperative consumers. Wiring each
/// tile's hover/drag input into the cursor is app-level integration (out of this
/// issue's scope, along with tile-layout persistence and drag-to-rearrange).
public struct WorkspaceView: View {
    @ObservedObject private var cursor: WorkspaceCursor
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
        .accessibilityLabel(L10n.string(.chartWorkspace))
    }

    /// A compact readout of the shared cursor's time and distance positions.
    private var cursorReadout: some View {
        HStack(spacing: 16) {
            Text(String(format: "t = %.2f s", cursor.timePosition))
            Text(String(format: "d = %.1f m", cursor.distancePosition))
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundColor(.secondary)
    }
}
