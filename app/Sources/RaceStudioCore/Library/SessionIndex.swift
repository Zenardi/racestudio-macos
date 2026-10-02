import Foundation

/// An in-memory index of decoded/imported sessions, keyed by a stable content id
/// (issue 5.3).
///
/// `SessionIndex` summarises each ``Session`` into a ``SessionSummary`` and keeps
/// them de-duplicated by content: re-adding the same file updates its entry in
/// place. It provides a case-insensitive ``search(_:)`` and a structured
/// ``filter(_:)``, both returning summaries ordered by date descending. The index
/// is `Codable`, so ``LibraryStore`` can persist the whole thing as JSON; only
/// the summaries are encoded (the injected clock is not persisted).
public final class SessionIndex: Codable, Equatable {

    private var storage: [String: SessionSummary]
    private var collectionStorage: [String: SessionCollection] = [:]
    /// Track id → the name the user gave that circuit. Kept keyed by track rather
    /// than copied per session so naming a circuit once covers every session
    /// recorded there, including ones imported later.
    private var trackNames: [String: String] = [:]
    /// The user's garage, by ``Kart/id``.
    private var kartStorage: [String: Kart] = [:]
    /// Track key (``trackKey(of:)``) → the kart last assigned to a session there,
    /// pre-filled on the next session imported from that track.
    private var trackKarts: [String: String] = [:]
    private let now: () -> Date

    /// - Parameter now: clock used to stamp ``SessionSummary/importedAt``
    ///   (injected so tests are deterministic; defaults to the wall clock).
    public init(now: (() -> Date)? = nil) {
        self.storage = [:]
        self.now = now ?? Date.init
    }

    /// All summaries, ordered by session date descending.
    public var summaries: [SessionSummary] {
        Self.byDateDescending(storage.values)
    }

    /// Derive a ``SessionSummary`` for `session` and store it, keyed by content
    /// id. Re-adding the same content updates the existing entry (new
    /// ``SessionSummary/sourceURL``/``SessionSummary/importedAt``) rather than
    /// creating a duplicate. Returns the stored summary.
    @discardableResult
    public func add(
        _ session: Session, sourceURL: URL, track: DetectedTrackInfo? = nil
    ) -> SessionSummary {
        let trackID = track?.id
        var summary = Self.summarize(session, sourceURL: sourceURL, importedAt: now())
        // Re-importing the same content must not discard a name the user chose: the
        // summary is re-derived from the decode, which knows nothing about renames.
        summary.customName = storage[summary.id]?.customName
        summary.trackID = trackID ?? storage[summary.id]?.trackID
        // Pick up the circuit's name now, so a session imported after the track was
        // named does not have to be renamed by hand.
        summary.trackNickname = summary.trackID.flatMap { trackNames[$0] }
        summary.trackLabel = track?.displayName ?? storage[summary.id]?.trackLabel
        summary.trackDirection = track?.direction ?? storage[summary.id]?.trackDirection
        // Keep the kart the user chose; a new session gets the track's last kart.
        let chosen = storage[summary.id]?.kartID ?? trackKarts[Self.trackKey(of: summary)]
        summary.kartID = chosen.flatMap { kartStorage[$0] == nil ? nil : $0 }
        storage[summary.id] = summary
        return summary
    }

    /// The name the user gave the circuit with `id`, or `nil`.
    public func trackName(id: String) -> String? {
        trackNames[id]
    }

    /// Name the circuit with `id`, retitling every session recorded there — the fix
    /// for a logger that stamps the venue inconsistently. A blank name clears it,
    /// restoring each session's decoded venue.
    public func renameTrack(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        trackNames[id] = trimmed.isEmpty ? nil : trimmed
        for (key, var summary) in storage where summary.trackID == id {
            summary.trackNickname = trackNames[id]
            storage[key] = summary
        }
    }

    /// The summary with the given content id, or `nil`.
    ///
    /// An O(1) dictionary read. Resolving a single row through ``summaries`` instead
    /// sorts the whole library — which the browser's preview pane did on every
    /// render.
    public func summary(id: String) -> SessionSummary? {
        storage[id]
    }

    /// Remove the summary with the given content id, if present, and prune it from
    /// every manual collection so a deleted session leaves no phantom member behind.
    public func remove(id: String) {
        guard storage.removeValue(forKey: id) != nil else { return }
        for (key, collection) in collectionStorage where collection.memberIDs.contains(id) {
            collectionStorage[key] = collection.removing(id)
        }
    }

    /// Set (or clear) the user-chosen display name of the summary with `id`.
    ///
    /// A blank or whitespace-only name **clears** the override rather than blanking
    /// the title, so the decoded venue comes back; the name is otherwise trimmed.
    /// Renaming an id that is not in the index does nothing.
    public func rename(id: String, to name: String) {
        guard var summary = storage[id] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        summary.customName = trimmed.isEmpty ? nil : trimmed
        storage[id] = summary
    }

    /// Case-insensitive substring search across venue, vehicle, and driver.
    /// An empty query returns every summary. Results are date-descending.
    public func search(_ query: String) -> [SessionSummary] {
        Self.byDateDescending(storage.values.filter { $0.matchesText(query) })
    }

    /// Return the summaries matching every set predicate in `spec`. An empty
    /// spec returns every summary. Results are date-descending.
    public func filter(_ spec: FilterSpec) -> [SessionSummary] {
        Self.byDateDescending(storage.values.filter(spec.matches))
    }

    // MARK: - Garage

    /// Every kart, ordered by name (case-insensitive), tie-broken by id.
    public var karts: [Kart] {
        kartStorage.values.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// The kart with `id`, or `nil`.
    public func kart(id: String) -> Kart? {
        kartStorage[id]
    }

    /// Add `kart` to the garage, or update the kart with its id. Stored
    /// ``Kart/normalized``.
    public func upsertKart(_ kart: Kart) {
        kartStorage[kart.id] = kart.normalized
    }

    /// Remove the kart with `id`: its sessions become unassigned and no track
    /// pre-fills it any more.
    public func removeKart(id: String) {
        guard kartStorage.removeValue(forKey: id) != nil else { return }
        for (key, var summary) in storage where summary.kartID == id {
            summary.kartID = nil
            storage[key] = summary
        }
        trackKarts = trackKarts.filter { $0.value != id }
    }

    /// Assign the kart with `kartID` to the session with `sessionID`, or clear the
    /// assignment with `nil`. Assigning also makes it the kart pre-filled for the
    /// next session imported from the same track. An unknown session or kart
    /// changes nothing.
    public func assignKart(_ kartID: String?, toSession sessionID: String) {
        guard var summary = storage[sessionID] else { return }
        if let kartID {
            guard kartStorage[kartID] != nil else { return }
            trackKarts[Self.trackKey(of: summary)] = kartID
        }
        summary.kartID = kartID
        storage[sessionID] = summary
    }

    /// The kart pre-filled for new sessions at `summary`'s track, or `nil`.
    public func defaultKart(forTrackOf summary: SessionSummary) -> Kart? {
        trackKarts[Self.trackKey(of: summary)].flatMap { kartStorage[$0] }
    }

    /// What "the same track" means for the kart default: the recognized circuit
    /// when there is one, else the logger's venue name.
    static func trackKey(of summary: SessionSummary) -> String {
        if let trackID = summary.trackID { return "track:\(trackID)" }
        return "venue:\(summary.venue.lowercased())"
    }

    // MARK: - Recent (issue 8.15)

    /// The `limit` most-recently *imported* sessions, newest first — RS3's
    /// "Recent" collection. Ranked by ``SessionSummary/importedAt`` (not session
    /// date), tie-broken by date-descending then content id so the order is
    /// deterministic. A non-positive `limit` returns none; a `limit` beyond the
    /// library size returns all.
    public func recent(limit: Int) -> [SessionSummary] {
        guard limit > 0 else { return [] }
        let ordered = storage.values.sorted { lhs, rhs in
            if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        return Array(ordered.prefix(limit))
    }

    // MARK: - Facets (issue 8.15)

    /// The distinct, non-empty values of `facet` across the library, sorted
    /// case-insensitively — the choices offered by the browser's facet controls.
    public func facetValues(_ facet: SessionFacet) -> [String] {
        let values = storage.values.map { facet.value(in: $0) }.filter { !$0.isEmpty }
        return Array(Set(values)).sorted { lhs, rhs in
            // Deterministic across runs: break case-insensitive ties (e.g. "BMW"
            // vs "bmw") on the raw value, since Set iteration order is randomized.
            let order = lhs.localizedCaseInsensitiveCompare(rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    // MARK: - Collections (issue 8.15)

    /// All collections, ordered by name (case-insensitive), tie-broken by id so
    /// the sidebar order is deterministic.
    public var collections: [SessionCollection] {
        collectionStorage.values.sorted { lhs, rhs in
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }
    }

    /// The collection with the given id, or `nil`.
    public func collection(id: String) -> SessionCollection? {
        collectionStorage[id]
    }

    /// Add `collection`, replacing any existing one with the same id.
    public func upsertCollection(_ collection: SessionCollection) {
        collectionStorage[collection.id] = collection
    }

    /// Remove the collection with the given id, if present.
    public func removeCollection(id: String) {
        collectionStorage[id] = nil
    }

    /// The sessions belonging to `collection`:
    /// - a **smart** collection resolves through its rule (date-descending);
    /// - a **manual** collection resolves its curated member ids in order,
    ///   skipping any that are no longer in the index.
    public func sessions(in collection: SessionCollection) -> [SessionSummary] {
        switch collection.kind {
        case .smart(let rule):
            return filter(rule)
        case .manual(let memberIDs):
            return memberIDs.compactMap { storage[$0] }
        }
    }

    // MARK: - Derivation

    /// Build a ``SessionSummary`` from a session. `bestLap` is the fastest lap
    /// duration — the minimum over finite, non-negative laps, matching the
    /// upstream best-lap rule in `SessionSummaryViewModel` — or `nil` with no
    /// (valid) laps. A freshly added session is assumed available;
    /// ``LibraryStore/load(from:)`` recomputes availability against disk.
    private static func summarize(
        _ session: Session, sourceURL: URL, importedAt: Date
    ) -> SessionSummary {
        let metadata = session.metadata
        let fastest = session.laps.map(\.durationS)
            .filter { $0.isFinite && $0 >= 0 }
            .min()
        return SessionSummary(
            id: contentID(for: session),
            venue: metadata.track,
            date: Date(timeIntervalSince1970: TimeInterval(metadata.datetimeUtc)),
            vehicle: metadata.vehicle,
            driver: metadata.driver,
            lapCount: session.laps.count,
            bestLap: fastest.map { .seconds($0) },
            sourceURL: sourceURL,
            importedAt: importedAt,
            isAvailable: true,
            // RS3's "championship" facet is the session's series.
            // comment/logger are not surfaced by the decoder yet (empty).
            championship: metadata.series)
    }

    /// Recompute ``SessionSummary/isAvailable`` for every summary against disk —
    /// a dangling reference (moved/deleted source) is flagged, never dropped.
    func refreshAvailability(fileManager: FileManager = .default) {
        for (id, var summary) in storage {
            summary.isAvailable = fileManager.fileExists(atPath: summary.sourceURL.path)
            storage[id] = summary
        }
    }

    private static func byDateDescending<S: Sequence>(_ summaries: S) -> [SessionSummary]
    where S.Element == SessionSummary {
        // Date descending, breaking ties on the stable content id so the order is
        // deterministic across runs (dictionary iteration order is not, and
        // `sorted` is not guaranteed stable).
        summaries.sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id < rhs.id
        }
    }

    // MARK: - Codable (summaries only; the clock is not persisted)

    /// Generation of the decoder whose output these summaries were derived from.
    ///
    /// A summary caches values produced by the decoder at import time — lap
    /// count, channel listing, and the content hash that keys the row. When the
    /// decoder changes what it extracts, every cached row is both **wrong** and
    /// **un-updatable**: re-importing the same file hashes differently, so it
    /// lands as a second row beside the stale one. Bump this whenever a decode
    /// change alters summarised output, and ``LibraryStore/load(from:)`` drops
    /// the superseded rows instead of showing them forever.
    ///
    /// - 1: initial (implicit — files written before this key existed).
    /// - 2: data-message resynchronisation; files whose stream referenced a
    ///   channel with no `CHS` definition previously summarised as 0 laps and
    ///   0 channels.
    public static let decoderGeneration = 2

    /// The generation stamped on the decoded document, defaulting to `1` for a
    /// library written before the key existed.
    public private(set) var decoderGeneration = SessionIndex.decoderGeneration

    private enum CodingKeys: String, CodingKey {
        case summaries, collections, decoderGeneration, trackNames, karts, trackKarts
    }

    public convenience init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.decoderGeneration =
            ((try? container.decodeIfPresent(Int.self, forKey: .decoderGeneration)) ?? nil) ?? 1
        let list = try container.decode([SessionSummary].self, forKey: .summaries)
        storage = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        // `collections` is optional AND lenient. A 5.3/8.14-era library (no such
        // key) loads with none; and because a collection's rule/kind is a
        // hand-editable, schema-evolving document, a single malformed entry is
        // *skipped* rather than throwing — which would otherwise discard the whole
        // library index (every summary too) via LibraryStore's corrupt-index path.
        let wrapped = (try? container.decodeIfPresent(
            [FailableDecodable<SessionCollection>].self, forKey: .collections)) ?? nil
        trackNames = ((try? container.decodeIfPresent(
            [String: String].self, forKey: .trackNames)) ?? nil) ?? [:]
        // The garage is optional on disk (libraries before it existed) and, like
        // collections, lenient: one unreadable kart is skipped, not fatal.
        let savedKarts = ((try? container.decodeIfPresent(
            [FailableDecodable<Kart>].self, forKey: .karts)) ?? nil)?.compactMap(\.value) ?? []
        kartStorage = Dictionary(savedKarts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        trackKarts = ((try? container.decodeIfPresent(
            [String: String].self, forKey: .trackKarts)) ?? nil) ?? [:]
        let savedCollections = wrapped?.compactMap(\.value) ?? []
        collectionStorage = Dictionary(
            savedCollections.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encode id-sorted for stable, diff-friendly on-disk output.
        try container.encode(storage.values.sorted { $0.id < $1.id }, forKey: .summaries)
        try container.encode(collectionStorage.values.sorted { $0.id < $1.id }, forKey: .collections)
        try container.encode(SessionIndex.decoderGeneration, forKey: .decoderGeneration)
        try container.encode(trackNames, forKey: .trackNames)
        try container.encode(kartStorage.values.sorted { $0.id < $1.id }, forKey: .karts)
        try container.encode(trackKarts, forKey: .trackKarts)
    }

    /// Drop every cached summary, keeping user-authored collections. Used when a
    /// library was written by a superseded decoder (see ``decoderGeneration``).
    func discardSummaries() {
        storage.removeAll()
    }

    /// Whether any circuit has been named by the user (track names are
    /// user-authored, so — like collections — they survive a generation purge).
    var hasTrackNames: Bool { !trackNames.isEmpty }

    public static func == (lhs: SessionIndex, rhs: SessionIndex) -> Bool {
        lhs.storage == rhs.storage && lhs.collectionStorage == rhs.collectionStorage
            && lhs.trackNames == rhs.trackNames && lhs.kartStorage == rhs.kartStorage
            && lhs.trackKarts == rhs.trackKarts
    }
}

/// Decodes `T`, swallowing a per-element failure to `nil` instead of throwing.
/// Used to decode `collections` leniently: one malformed collection is skipped
/// rather than aborting the whole index decode (see ``SessionIndex/init(from:)``).
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
