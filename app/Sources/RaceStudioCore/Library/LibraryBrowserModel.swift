import Foundation

/// The session library browser (issue 8.14) — the RaceStudio 3 "choose what to
/// analyze" window's model, over the 5.3 ``SessionIndex`` / ``LibraryStore``.
///
/// It lists indexed sessions date-descending, imports add to the index (dedup by
/// content id via ``SessionIndex/add(_:sourceURL:)``), the left filtering column
/// (a vehicle facet + free-text search) narrows the list, and a selected session
/// previews its laps summary + map thumbnail — decoded through the injected
/// ``SessionLoading`` and read via ``AnalysisSession`` — without opening the full
/// analysis workspace. A missing or corrupt library loads as empty (the 5.3
/// ``LibraryStore/load(from:)`` semantics), so the browser never crashes on a bad
/// index.
///
/// `@MainActor` so every `@Published` mutation is observed on the main actor.
@MainActor
public final class LibraryBrowserModel: ObservableObject {

    private let index: SessionIndex
    private let loader: SessionLoading?

    /// The visible (filtered) sessions, date-descending.
    @Published public private(set) var sessions: [SessionSummary]
    /// The active vehicle facet in the filtering column, or `nil` for "all".
    @Published public private(set) var vehicleFilter: String?
    /// The free-text query matched across venue/vehicle/driver.
    @Published public private(set) var searchText: String = ""
    /// The selected session's content id, or `nil` when nothing is selected.
    @Published public private(set) var selectedID: String?
    /// The preview for the selected session, or `nil` (none selected / not loaded).
    @Published public private(set) var preview: SessionPreview?
    /// `true` when the last preview load failed — the browser degrades to no
    /// preview rather than propagating the error.
    @Published public private(set) var previewFailed = false

    /// - Parameters:
    ///   - index: the session index to browse (defaults to an empty library).
    ///   - loader: the decoder used to read a session's preview inputs, or `nil`
    ///     (then ``loadPreview()`` is a no-op — e.g. list-only tests).
    public init(index: SessionIndex = SessionIndex(), loader: SessionLoading? = nil) {
        self.index = index
        self.loader = loader
        self.sessions = index.summaries
    }

    /// Load the library at `url` via `store`, degrading to an empty library on a
    /// missing or corrupt file (the 5.3 ``LibraryStore/load(from:)`` semantics).
    public convenience init(loadingFrom url: URL,
                            store: LibraryStore = LibraryStore(),
                            loader: SessionLoading? = nil) {
        self.init(index: store.load(from: url), loader: loader)
    }

    /// The distinct vehicles present, sorted — the filtering column's facets.
    public var vehicles: [String] {
        Set(index.summaries.map(\.vehicle)).sorted()
    }

    /// The selected summary, resolved from ``selectedID`` (or `nil`).
    public var selectedSummary: SessionSummary? {
        selectedID.flatMap { id in index.summaries.first { $0.id == id } }
    }

    /// Add a decoded session to the library (dedup by content id) and refresh the
    /// visible list. Re-adding the same content updates its entry in place.
    /// Returns the stored summary.
    @discardableResult
    public func add(_ session: Session, sourceURL: URL) -> SessionSummary {
        let summary = index.add(session, sourceURL: sourceURL)
        refresh()
        return summary
    }

    /// Persist the library to `url` via `store` so imported sessions list again on
    /// the next launch (issue 8.14 — "when the browser opens, they list from the
    /// LibraryStore"). Throws ``LibraryError/ioFailure`` if the write cannot commit.
    public func save(to url: URL, using store: LibraryStore = LibraryStore()) throws {
        try store.save(index, to: url)
    }

    /// Set the vehicle facet (or `nil` to clear it) and refresh the list.
    public func setVehicleFilter(_ vehicle: String?) {
        vehicleFilter = vehicle
        refresh()
    }

    /// Set the free-text query and refresh the list.
    public func search(_ text: String) {
        searchText = text
        refresh()
    }

    /// Select a session by content id (or `nil` to clear the selection). Clears
    /// any stale preview until ``loadPreview()`` runs for the new selection.
    public func select(_ id: String?) {
        selectedID = id
        preview = nil
        previewFailed = false
    }

    /// Load the preview (laps summary + map thumbnail) for the current selection
    /// through the injected loader. On failure it clears the preview and sets
    /// ``previewFailed`` rather than propagating — the browser stays usable. A
    /// selection change mid-load discards the stale result.
    public func loadPreview() async {
        guard let id = selectedID, let summary = selectedSummary, let loader else { return }
        do {
            let loaded = try await loader.load(summary.sourceURL) { _ in }
            guard selectedID == id else { return }
            let coordinates = loaded.dataSource
                .map { AnalysisSession(session: loaded.session, dataSource: $0).gpsTrack().map(\.coordinate) }
                ?? []
            preview = SessionPreview(session: loaded.session, coordinates: coordinates)
            previewFailed = false
        } catch {
            guard selectedID == id else { return }
            preview = nil
            previewFailed = true
        }
    }

    /// Recompute the visible list: the 5.3 text search first (empty → all,
    /// date-descending), then the vehicle facet, preserving the ordering.
    private func refresh() {
        var result = index.search(searchText)
        if let vehicleFilter {
            result = result.filter { $0.vehicle.caseInsensitiveCompare(vehicleFilter) == .orderedSame }
        }
        sessions = result
    }
}
