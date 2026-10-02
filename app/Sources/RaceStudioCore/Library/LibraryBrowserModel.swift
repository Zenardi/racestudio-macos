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

/// What removing a session from the library should do with the file behind it.
///
/// Deleting is offered as an explicit choice rather than a single destructive
/// action: the library row and the bytes on disk are separate things to lose, and
/// only RaceStudio's own copy is ever a candidate — the file the user picked is
/// never deleted by either case.
public enum SessionDeletion: Equatable, Sendable {
    /// Forget the row; leave RaceStudio's copy of the file on disk.
    case removeFromLibrary
    /// Forget the row and delete RaceStudio's copy of the file.
    case discardingCopy
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
    /// RaceStudio's own copy store, or `nil` when the browser is list-only (the
    /// non-filesystem test configuration). Deleting can only offer to remove a file
    /// this store owns.
    private let files: ManagedFileStore?

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
    ///   - files: the store holding RaceStudio's own copy of each imported file, or
    ///     `nil` when the browser owns no files (then nothing is discardable).
    public init(index: SessionIndex = SessionIndex(), loader: SessionLoading? = nil,
                files: ManagedFileStore? = nil) {
        self.index = index
        self.loader = loader
        self.files = files
        self.sessions = index.summaries
    }

    /// Where every user edit is written back, or `nil` for an in-memory library
    /// (tests). Set when the library is loaded from a file.
    private var autosave: (url: URL, store: LibraryStore)?

    /// Load the library at `url` via `store`, degrading to an empty library on a
    /// missing or corrupt file (the 5.3 ``LibraryStore/load(from:)`` semantics).
    public convenience init(loadingFrom url: URL,
                            store: LibraryStore = LibraryStore(),
                            loader: SessionLoading? = nil,
                            files: ManagedFileStore? = nil) {
        self.init(index: store.load(from: url), loader: loader, files: files)
        autosave = (url, store)
    }

    /// Write the library back after a user edit, so a rename, a collection or a
    /// kart is never lost on quit. Before this only an import saved. A failed
    /// write is not fatal: the edit is in memory and the next save retries.
    private func persist() {
        guard let autosave else { return }
        try? autosave.store.save(index, to: autosave.url)
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
        selectedID.flatMap(index.summary(id:))
    }

    /// Add a decoded session to the library (dedup by content id) and refresh the
    /// visible list. Re-adding the same content updates its entry in place.
    /// Returns the stored summary.
    @discardableResult
    public func add(
        _ session: Session, sourceURL: URL, track: DetectedTrackInfo? = nil
    ) -> SessionSummary {
        let summary = index.add(session, sourceURL: sourceURL, track: track)
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
        persist()
    }

    /// Remove a collection; if it was the active scope, fall back to "all".
    public func removeCollection(id: String) {
        index.removeCollection(id: id)
        if scope == .collection(id) { scope = .all }
        refresh()
        persist()
    }

    /// Drag a session into a manual collection (idempotent), persisting the
    /// curated membership in the index. Call ``save(to:using:)`` to write to disk.
    public func addSession(_ sessionID: String, toCollection collectionID: String) {
        guard let collection = index.collection(id: collectionID) else { return }
        index.upsertCollection(collection.adding(sessionID))
        refresh()
        persist()
    }

    // MARK: - Naming and removal

    /// Give the session with `id` a user-chosen display name, or clear it with a
    /// blank string so the decoded venue comes back. Call ``save(to:using:)`` to
    /// persist. Renaming an unknown id does nothing.
    public func rename(id: String, to name: String) {
        index.rename(id: id, to: name)
        refresh()
        persist()
    }

    /// Name the circuit with `id`, retitling every session recorded there. A blank
    /// name clears it. Call ``save(to:using:)`` to persist.
    public func renameTrack(id: String, to name: String) {
        index.renameTrack(id: id, to: name)
        refresh()
        persist()
    }

    /// The name the user gave the circuit with `id`, or `nil`.
    public func trackName(id: String) -> String? { index.trackName(id: id) }

    // MARK: - Garage

    /// The garage, ordered by name.
    public var karts: [Kart] { index.karts }

    /// The kart with `id`, or `nil`.
    public func kart(id: String) -> Kart? { index.kart(id: id) }

    /// The kart assigned to the session with content id `sessionID`, or `nil`.
    public func kart(forSession sessionID: String) -> Kart? {
        index.summary(id: sessionID)?.kartID.flatMap(index.kart(id:))
    }

    /// The kart assigned to the library's entry for `session` (matched by
    /// content), or `nil` — how the analysis view finds the kart of the session
    /// it opened.
    public func kart(for session: Session) -> Kart? {
        kart(forSession: SessionIndex.contentID(for: session))
    }

    /// Add `kart` to the garage, or update the kart with its id.
    public func saveKart(_ kart: Kart) {
        index.upsertKart(kart)
        refresh()
        persist()
    }

    /// Remove the kart with `id`; its sessions become unassigned.
    public func deleteKart(id: String) {
        index.removeKart(id: id)
        if facets.kartID == id { facets.kartID = nil }
        refresh()
        persist()
    }

    /// Assign the kart with `kartID` (or none) to the session with `sessionID`;
    /// it becomes the default for new sessions from that session's track.
    public func assignKart(_ kartID: String?, toSession sessionID: String) {
        index.assignKart(kartID, toSession: sessionID)
        refresh()
        persist()
    }

    /// The kart filter: only sessions driven on the kart with `id`, or all with
    /// `nil`.
    public var kartFilter: String? { facets.kartID }

    /// Filter the list to the kart with `id`, or clear the filter with `nil`.
    public func setKartFilter(_ id: String?) {
        facets.kartID = id
        refresh()
    }

    /// Whether RaceStudio owns a copy of this session's file, and can therefore
    /// offer to delete it. `false` for a row imported before adoption existed,
    /// which still points at the user's own file.
    public func canDiscardCopy(id: String) -> Bool {
        guard let files, let summary = index.summary(id: id) else { return false }
        return files.isManaged(summary.sourceURL)
    }

    /// Remove the session with `id` from the library, and — with
    /// ``SessionDeletion/discardingCopy`` — delete RaceStudio's own copy of its file.
    ///
    /// The row is **always** removed, including when discarding the file fails: the
    /// error is thrown afterwards so the caller can report it without the row
    /// reappearing. A file outside the managed store is never deleted; asking to
    /// discard one raises ``ManagedFileStore/StorageError/notManaged``.
    public func delete(id: String, _ deletion: SessionDeletion) throws {
        guard let summary = index.summary(id: id) else { return }
        index.remove(id: id)
        if selectedID == id { select(nil) }
        refresh()
        persist()
        guard deletion == .discardingCopy else { return }
        guard let files else { throw ManagedFileStore.StorageError.notManaged }
        try files.discard(summary.sourceURL)
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
            let track = loaded.dataSource
                .map { AnalysisSession(session: loaded.session, dataSource: $0).gpsTrack() } ?? []
            preview = SessionPreview(session: loaded.session, track: track)
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
