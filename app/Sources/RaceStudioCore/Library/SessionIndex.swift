import CryptoKit
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
    public func add(_ session: Session, sourceURL: URL) -> SessionSummary {
        let summary = Self.summarize(session, sourceURL: sourceURL, importedAt: now())
        storage[summary.id] = summary
        return summary
    }

    /// Remove the summary with the given content id, if present.
    public func remove(id: String) {
        storage[id] = nil
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
        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    /// A stable, deterministic content id for `session` — a SHA-256 over its
    /// metadata, laps, and channel listing. Two decodes of the same file hash
    /// identically (so re-adding updates rather than duplicates); different
    /// content hashes differently. Deterministic across process runs, unlike
    /// `Hashable`, so it is safe to persist as a key.
    ///
    /// Every field is **length-prefixed** into the hash so the encoding is
    /// injective: a `|`/`:`/newline inside a value (e.g. a track named `"A|B"`)
    /// can never forge the field boundaries of a genuinely different session.
    public static func contentID(for session: Session) -> String {
        var hasher = SHA256()
        func feed(_ value: String) {
            var length = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(value.utf8))
        }
        let metadata = session.metadata
        for field in [metadata.vehicle, metadata.track, metadata.driver,
                      metadata.session, metadata.series, metadata.logDate,
                      metadata.logTime, String(metadata.datetimeUtc)] {
            feed(field)
        }
        feed(String(session.laps.count))
        for lap in session.laps {
            feed(String(lap.index)); feed(String(lap.startTimeS))
            feed(String(lap.durationS)); feed(String(lap.endTimeS))
        }
        feed(String(session.channels.count))
        for channel in session.channels {
            feed(channel.name); feed(channel.unit); feed(String(channel.sampleRateHz))
            feed(String(channel.decimals)); feed(String(channel.sampleCount))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    private enum CodingKeys: String, CodingKey { case summaries, collections }

    public convenience init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decode([SessionSummary].self, forKey: .summaries)
        storage = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        // `collections` is optional on disk so a 5.3/8.14-era library (no such key)
        // still loads, with no collections.
        let savedCollections = try container.decodeIfPresent([SessionCollection].self, forKey: .collections) ?? []
        collectionStorage = Dictionary(
            savedCollections.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Encode id-sorted for stable, diff-friendly on-disk output.
        try container.encode(storage.values.sorted { $0.id < $1.id }, forKey: .summaries)
        try container.encode(collectionStorage.values.sorted { $0.id < $1.id }, forKey: .collections)
    }

    public static func == (lhs: SessionIndex, rhs: SessionIndex) -> Bool {
        lhs.storage == rhs.storage && lhs.collectionStorage == rhs.collectionStorage
    }
}
