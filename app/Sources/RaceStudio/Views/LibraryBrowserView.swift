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
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

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
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("New Smart Collection from Filters") {
                        library.addCollection(.smart(
                            id: UUID().uuidString, name: "Smart Collection", rule: library.facets))
                    }
                    Button("New Manual Collection") {
                        library.addCollection(.manual(id: UUID().uuidString, name: "Manual Collection"))
                    }
                } label: { Label("New Collection", systemImage: "folder.badge.plus") }
                .help("Create a smart (rule-based) or manual (drag-and-drop) collection")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) { Label("Import…", systemImage: "plus") }
                    .help("Import a .xrk / .xrz telemetry file into the library")
            }
        }
        .task(id: library.selectedID) { await library.loadPreview() }
    }

    // MARK: - Left column (collections sidebar + faceted search)

    private var filterColumn: some View {
        List {
            Section("Library") {
                scopeRow("All Sessions", systemImage: "square.grid.2x2", active: library.scope == .all) {
                    library.showAll()
                }
                scopeRow("Recent", systemImage: "clock", active: isRecentScope) {
                    library.showRecent()
                }
            }

            if !library.collections.isEmpty {
                Section("Collections") {
                    ForEach(library.collections) { collection in
                        collectionRow(collection)
                    }
                }
            }

            Section("Search") {
                TextField("Venue, vehicle, driver", text: searchBinding)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Facets") {
                ForEach(SessionFacet.allCases) { facet in
                    let values = library.facetValues(facet)
                    if !values.isEmpty { facetPicker(facet, values: values) }
                }
            }
        }
    }

    /// A selectable scope row (All / Recent), highlighted when active.
    private func scopeRow(
        _ title: String, systemImage: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .fontWeight(active ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }

    /// A collection row — selecting it scopes the list; a **manual** collection is
    /// a drop target so sessions dragged from the list persist as a curated set.
    @ViewBuilder
    private func collectionRow(_ collection: SessionCollection) -> some View {
        let active = library.scope == .collection(collection.id)
        let row = Button {
            library.showCollection(id: collection.id)
        } label: {
            Label(collection.name, systemImage: collection.isSmart ? "gearshape" : "folder")
                .fontWeight(active ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { library.removeCollection(id: collection.id) }
        }

        if collection.isSmart {
            row
        } else {
            row.dropDestination(for: String.self) { ids, _ in
                for id in ids { library.addSession(id, toCollection: collection.id) }
                return !ids.isEmpty
            }
        }
    }

    /// A single-value picker for one facet ("All" clears it).
    private func facetPicker(_ facet: SessionFacet, values: [String]) -> some View {
        Picker(facet.title, selection: facetBinding(facet)) {
            Text("All").tag(String?.none)
            ForEach(values, id: \.self) { value in
                Text(value).tag(String?.some(value))
            }
        }
    }

    private var isRecentScope: Bool {
        if case .recent = library.scope { return true }
        return false
    }

    private var searchBinding: Binding<String> {
        Binding(get: { library.searchText }, set: { library.search($0) })
    }

    private func facetBinding(_ facet: SessionFacet) -> Binding<String?> {
        Binding(get: { facet.value(in: library.facets) }, set: { library.setFacet(facet, to: $0) })
    }

    // MARK: - Sessions list (date-descending)

    private var sessionList: some View {
        List(selection: idSelection) {
            ForEach(library.sessions) { summary in
                sessionRow(summary)
                    .tag(summary.id)
                    .draggable(summary.id)  // drag into a manual collection to curate it
            }
        }
        .overlay { if library.sessions.isEmpty { emptyState } }
    }

    private var idSelection: Binding<String?> {
        Binding(get: { library.selectedID }, set: { library.select($0) })
    }

    private func sessionRow(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
            HStack {
                Text(summary.venue.isEmpty ? "Unknown venue" : summary.venue)
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                if !summary.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.palette.negative.color(scheme))
                        .help("The source file is missing or moved")
                }
            }
            Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                .font(.token(theme.typography.caption))
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
            HStack(spacing: theme.spacing.xs + 2) {
                Text(summary.vehicle)
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                if !summary.driver.isEmpty {
                    Text("• \(summary.driver)")
                        .font(.token(theme.typography.caption))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                }
                Spacer()
                Text("\(summary.lapCount) lap\(summary.lapCount == 1 ? "" : "s")")
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
        }
        .padding(.vertical, theme.spacing.xs / 2)
    }

    private var emptyState: some View {
        BrandStateView(symbol: "tray",
                       title: "No sessions",
                       message: "Import a .xrk / .xrz file to get started.",
                       actionLabel: "Import…", action: onImport)
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
///
/// This is the **reference screen** for the brand tokens (issue 7.3, #141): every
/// colour, font, gap, and corner here is drawn from the `RaceStudioCore` ``Theme``
/// (via `\.theme`) rather than a hard-coded value, and it renders correctly in
/// both light and dark because the palette resolves per ``ColorScheme``.
private struct LibraryPreviewPane: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let summary: SessionSummary
    let preview: SessionPreview
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text(summary.venue.isEmpty ? "Unknown venue" : summary.venue)
                        .font(.token(theme.typography.title))
                        .foregroundStyle(theme.palette.textPrimary.color(scheme))
                    Text("\(summary.vehicle) • \(summary.driver)")
                        .font(.token(theme.typography.callout))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                }
                Spacer()
                Button(action: onOpen) {
                    Label("Open in Analysis", systemImage: "chart.xyaxis.line")
                        .foregroundStyle(theme.palette.onAccent.color(scheme))
                }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.palette.accent.color(scheme))
                    .disabled(!summary.isAvailable)
            }

            MapThumbnail(map: preview.map)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(theme.palette.surfaceElevated.color(scheme),
                            in: RoundedRectangle(cornerRadius: theme.radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.md)
                        .strokeBorder(theme.palette.separator.color(scheme)))

            Text("Laps")
                .font(.token(theme.typography.headline))
                .foregroundStyle(theme.palette.textPrimary.color(scheme))
            lapsTable
        }
        .padding(theme.spacing.lg)
        .background(theme.palette.surface.color(scheme))
    }

    private var lapsTable: some View {
        Table(preview.summary.laps) {
            TableColumn("Lap") { Text("\($0.number)").font(.token(theme.typography.readout)) }
            TableColumn("Time") { Text($0.time).font(.token(theme.typography.readout)) }
            TableColumn("") { lap in
                if lap.isBest {
                    Text("Best")
                        .font(.token(theme.typography.caption))
                        .foregroundStyle(theme.palette.positive.color(scheme))
                }
            }
        }
    }
}

/// Strokes the ``MapPreviewModel`` unit-box points as a racing line, scaled to the
/// view with a little inset. An empty preview shows a "no GPS" placeholder.
private struct MapThumbnail: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let map: MapPreviewModel

    var body: some View {
        GeometryReader { geo in
            if map.isEmpty {
                Text("No GPS track")
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
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
                // Brand accent — not the user's macOS system accent — so the racing
                // line stays the brand red and never collides with the green
                // `positive` best-lap marker.
                .stroke(theme.palette.accent.color(scheme),
                        style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}

/// A small "nothing here" placeholder (a lightweight stand-in for
/// `ContentUnavailableView`, which is macOS 14+, so the app keeps its macOS 13
/// floor). Brand-tokenized via ``BrandStateView`` (issue 7.5).
private struct ContentUnavailableMessage: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        BrandStateView(symbol: systemImage, title: title, message: message)
    }
}
