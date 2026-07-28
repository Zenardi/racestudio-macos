import Foundation

/// What the browser is currently showing (issue 8.15): the whole library, the
/// Recent collection, or a saved ``SessionCollection`` — narrowed further by the
/// free-text search and facet constraints.
public enum LibraryScope: Equatable, Sendable {
    /// Every indexed session.
    case all
    /// The `limit` most-recently imported sessions.
    case recent(Int)
    /// The saved collection with this id.
    case collection(String)
}

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

    /// Every indexed session, date-descending — the **unfiltered** library,
    /// independent of the active scope / search / facets. The Home dashboard reads
    /// this so its at-a-glance stats and recents reflect the whole library rather
    /// than whatever filter the browser happens to have left active.
    public var allSessions: [SessionSummary] { index.summaries }
    /// The facet constraints applied on top of the current scope + search.
    @Published public private(set) var facets = FilterSpec()
    /// What the list is scoped to (all / recent / a collection).
    @Published public private(set) var scope: LibraryScope = .all
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

    /// The distinct vehicles present, sorted — the 8.14 vehicle facet's choices.
    /// Defined in terms of ``facetValues(_:)`` so it cannot drift from the generic
    /// facet path (same distinct/empty-filter/ordering semantics).
    public var vehicles: [String] { facetValues(.vehicle) }

    /// The active vehicle facet, or `nil` for "all" (back-compat with 8.14).
    public var vehicleFilter: String? { facets.vehicle }

    /// The saved collections, ordered for the sidebar.
    public var collections: [SessionCollection] { index.collections }

    /// The distinct values offered for `facet` (its facet-control choices).
    public func facetValues(_ facet: SessionFacet) -> [String] { index.facetValues(facet) }

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

    /// Set the vehicle facet (or `nil` to clear it) and refresh the list — a thin
    /// adapter over ``setFacet(_:to:)`` for the 8.14 vehicle column.
    public func setVehicleFilter(_ vehicle: String?) {
        setFacet(.vehicle, to: vehicle)
    }

    /// Set (or clear, with `nil`) a facet constraint and refresh the list.
    public func setFacet(_ facet: SessionFacet, to value: String?) {
        facet.apply(value, to: &facets)
        refresh()
    }

    /// Set the free-text query and refresh the list.
    public func search(_ text: String) {
        searchText = text
        refresh()
    }

    // MARK: - Scope (issue 8.15)

    /// Show every indexed session.
    public func showAll() {
        scope = .all
        refresh()
    }

    /// Show the `limit` most-recently imported sessions (RS3 "Recent").
    public func showRecent(limit: Int = 20) {
        scope = .recent(limit)
        refresh()
    }

    /// Show the sessions in the saved collection with `id`.
    public func showCollection(id: String) {
        scope = .collection(id)
        refresh()
    }

    // MARK: - Collections (issue 8.15)

    /// Add (or replace by id) a collection, then refresh the visible list.
    public func addCollection(_ collection: SessionCollection) {
        index.upsertCollection(collection)
        refresh()
    }

    /// Remove a collection; if it was the active scope, fall back to "all".
    public func removeCollection(id: String) {
        index.removeCollection(id: id)
        if scope == .collection(id) { scope = .all }
        refresh()
    }

    /// Drag a session into a manual collection (idempotent), persisting the
    /// curated membership in the index. Call ``save(to:using:)`` to write to disk.
    public func addSession(_ sessionID: String, toCollection collectionID: String) {
        guard let collection = index.collection(id: collectionID) else { return }
        index.upsertCollection(collection.adding(sessionID))
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

    /// Recompute the visible list: the active scope first, then the free-text
    /// search, then the facet constraints — each step preserving the base ordering.
    private func refresh() {
        var result = scopedSessions()
        if !searchText.isEmpty { result = result.filter { $0.matchesText(searchText) } }
        result = result.filter(facets.matches)
        sessions = result
    }

    /// The base list for the active scope, before search/facets are applied.
    private func scopedSessions() -> [SessionSummary] {
        switch scope {
        case .all:
            return index.summaries
        case .recent(let limit):
            return index.recent(limit: limit)
        case .collection(let id):
            guard let collection = index.collection(id: id) else { return [] }
            return index.sessions(in: collection)
        }
    }
}
