import SwiftUI
import RaceStudioCore

/// The RaceStudio 3 "choose what to analyze" window (issue 8.14): a left filtering
/// column (search + vehicle facets), a date-descending sessions list, and a
/// preview pane (laps summary + racing-line thumbnail) — all driven by the Core
/// ``LibraryBrowserModel``. "Open" hands the selected session to full analysis;
/// "Import…" adds a telemetry file to the library.
///
/// This is the app's landing window, so launching RaceStudio shows a real browser
/// UI rather than a bare file-open panel. The view is thin: every list/filter/
/// preview decision lives in `RaceStudioCore`.
struct LibraryBrowserView: View {
    @ObservedObject var library: LibraryBrowserModel
    let onOpen: (SessionSummary) -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationSplitView {
            filterColumn
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            sessionList
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            previewPane
        }
        .navigationTitle("RaceStudio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) { Label("Import…", systemImage: "plus") }
                    .help("Import a .xrk / .xrz telemetry file into the library")
            }
        }
        .task(id: library.selectedID) { await library.loadPreview() }
    }

    // MARK: - Left filtering column (search + vehicle facets)

    private var filterColumn: some View {
        List(selection: vehicleSelection) {
            Section("Search") {
                TextField("Venue, vehicle, driver", text: searchBinding)
                    .textFieldStyle(.roundedBorder)
            }
            Section("Vehicle") {
                Text("All vehicles").tag(String?.none)
                ForEach(library.vehicles, id: \.self) { vehicle in
                    Text(vehicle).tag(String?.some(vehicle))
                }
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(get: { library.searchText }, set: { library.search($0) })
    }

    private var vehicleSelection: Binding<String?> {
        Binding(get: { library.vehicleFilter }, set: { library.setVehicleFilter($0) })
    }

    // MARK: - Sessions list (date-descending)

    private var sessionList: some View {
        List(selection: idSelection) {
            ForEach(library.sessions) { summary in
                sessionRow(summary).tag(summary.id)
            }
        }
        .overlay { if library.sessions.isEmpty { emptyState } }
    }

    private var idSelection: Binding<String?> {
        Binding(get: { library.selectedID }, set: { library.select($0) })
    }

    private func sessionRow(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(summary.venue.isEmpty ? "Unknown venue" : summary.venue).fontWeight(.semibold)
                Spacer()
                if !summary.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("The source file is missing or moved")
                }
            }
            Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(summary.vehicle).font(.caption)
                if !summary.driver.isEmpty {
                    Text("• \(summary.driver)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(summary.lapCount) lap\(summary.lapCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
            Text("No sessions").font(.headline)
            Text("Import a .xrk / .xrz file to get started.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Import…", action: onImport)
        }
        .padding()
    }

    // MARK: - Preview pane (laps summary + map thumbnail)

    @ViewBuilder
    private var previewPane: some View {
        if let summary = library.selectedSummary, let preview = library.preview {
            LibraryPreviewPane(summary: summary, preview: preview) { onOpen(summary) }
        } else if library.previewFailed {
            ContentUnavailableMessage(
                title: "Preview unavailable",
                systemImage: "exclamationmark.triangle",
                message: "The session couldn't be read. The source file may be missing or unsupported.")
        } else if library.selectedID != nil {
            ProgressView("Loading preview…")
        } else {
            ContentUnavailableMessage(
                title: "Select a session",
                systemImage: "sidebar.right",
                message: "Choose a session to preview its laps and racing line.")
        }
    }
}

/// The detail preview for one selected session (issue 8.14): its identity, a
/// racing-line thumbnail, and a laps table — with an "Open in Analysis" action.
private struct LibraryPreviewPane: View {
    let summary: SessionSummary
    let preview: SessionPreview
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(summary.venue.isEmpty ? "Unknown venue" : summary.venue).font(.title2).bold()
                    Text("\(summary.vehicle) • \(summary.driver)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onOpen) { Label("Open in Analysis", systemImage: "chart.xyaxis.line") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!summary.isAvailable)
            }

            MapThumbnail(map: preview.map)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text("Laps").font(.headline)
            lapsTable
        }
        .padding()
    }

    private var lapsTable: some View {
        Table(preview.summary.laps) {
            TableColumn("Lap") { Text("\($0.number)") }
            TableColumn("Time") { Text($0.time) }
            TableColumn("") { lap in
                if lap.isBest { Text("Best").font(.caption).foregroundStyle(.green) }
            }
        }
    }
}

/// Strokes the ``MapPreviewModel`` unit-box points as a racing line, scaled to the
/// view with a little inset. An empty preview shows a "no GPS" placeholder.
private struct MapThumbnail: View {
    let map: MapPreviewModel

    var body: some View {
        GeometryReader { geo in
            if map.isEmpty {
                Text("No GPS track")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Path { path in
                    let inset: CGFloat = 12
                    let width = max(geo.size.width - inset * 2, 1)
                    let height = max(geo.size.height - inset * 2, 1)
                    let scaled = map.points.map { point in
                        CGPoint(x: inset + point.x * width, y: inset + point.y * height)
                    }
                    path.addLines(scaled)
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}

/// A small "nothing here" placeholder (a lightweight stand-in for
/// `ContentUnavailableView`, which is macOS 14+, so the app keeps its macOS 13
/// floor).
private struct ContentUnavailableMessage: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
