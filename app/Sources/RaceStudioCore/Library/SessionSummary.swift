import Foundation

/// A lightweight, browsable summary of one indexed session (issue 5.3).
///
/// The session library derives a `SessionSummary` from a decoded (M1) or
/// imported (5.2) ``Session`` so the app can present a searchable, filterable
/// list without re-decoding files. It carries only display/identity fields —
/// never bulk samples — and is `Codable` so the whole index persists to disk as
/// JSON.
///
/// `id` is a stable, content-derived hash (see ``SessionIndex/contentID(for:)``)
/// so re-importing the same file updates its entry rather than duplicating it.
/// `isAvailable` reflects whether ``sourceURL`` still resolves on disk; it is
/// recomputed when the index is loaded so dangling references surface instead of
/// being dropped silently.
public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {

    /// Stable content id (keys the session in the index).
    public let id: String
    /// Track/venue name (from the session metadata).
    public let venue: String
    /// Session start, derived from the metadata's UTC timestamp.
    public let date: Date
    /// Vehicle identifier.
    public let vehicle: String
    /// Driver / racer name.
    public let driver: String
    /// Championship / series name (RS3 "championship" facet), from the metadata's
    /// `series`. Empty when the session carries no series.
    public let championship: String
    /// Free-text comment/notes (RS3 "comment" facet). The `.xrk` decoder does not
    /// surface this yet, so it is empty for decoded sessions; the field and its
    /// facet exist so the filter works the moment a comment is populated.
    public let comment: String
    /// Logging device name (RS3 "logger" facet). Not surfaced by the decoder yet
    /// (empty for decoded sessions); see ``comment``.
    public let logger: String
    /// Number of laps in the session.
    public let lapCount: Int
    /// Fastest lap time, or `nil` when the session has no laps.
    public let bestLap: Duration?
    /// The file this summary was imported/decoded from.
    public let sourceURL: URL
    /// When this session was added to the library.
    public let importedAt: Date
    /// Whether ``sourceURL`` currently resolves on disk. This is transient state
    /// derived from the filesystem — deliberately **not** persisted, since
    /// ``LibraryStore/load(from:)`` always recomputes it (a source deleted after
    /// the last save must still be flagged). It defaults to `true` on decode
    /// until that recompute runs.
    public var isAvailable: Bool = true

    public init(
        id: String, venue: String, date: Date, vehicle: String, driver: String,
        lapCount: Int, bestLap: Duration?, sourceURL: URL, importedAt: Date,
        isAvailable: Bool, championship: String = "", comment: String = "", logger: String = ""
    ) {
        self.id = id
        self.venue = venue
        self.date = date
        self.vehicle = vehicle
        self.driver = driver
        self.championship = championship
        self.comment = comment
        self.logger = logger
        self.lapCount = lapCount
        self.bestLap = bestLap
        self.sourceURL = sourceURL
        self.importedAt = importedAt
        self.isAvailable = isAvailable
    }

    /// `isAvailable` is intentionally omitted — it is transient, filesystem-derived
    /// state (see above), so it is never encoded and defaults on decode.
    private enum CodingKeys: String, CodingKey {
        case id, venue, date, vehicle, driver, championship, comment, logger,
             lapCount, bestLap, sourceURL, importedAt
    }

    /// Custom decode so the 8.15 facet fields (``championship``/``comment``/
    /// ``logger``) are **optional on disk**: a library.json written by 5.3/8.14
    /// (before these keys existed) still decodes, defaulting them to empty. The
    /// synthesised `encode(to:)` always writes them, so freshly saved libraries
    /// round-trip exactly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        venue = try container.decode(String.self, forKey: .venue)
        date = try container.decode(Date.self, forKey: .date)
        vehicle = try container.decode(String.self, forKey: .vehicle)
        driver = try container.decode(String.self, forKey: .driver)
        championship = try container.decodeIfPresent(String.self, forKey: .championship) ?? ""
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        logger = try container.decodeIfPresent(String.self, forKey: .logger) ?? ""
        lapCount = try container.decode(Int.self, forKey: .lapCount)
        bestLap = try container.decodeIfPresent(Duration.self, forKey: .bestLap)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        // isAvailable is transient; it defaults to true and LibraryStore.load recomputes it.
    }
}

extension SessionSummary {
    /// Case-insensitive substring match across venue, vehicle, and driver — the
    /// library's free-text search (issue 5.3). An empty query matches everything.
    /// Shared by ``SessionIndex/search(_:)`` and the browser's scoped search so
    /// they agree on what "matches the text" means.
    func matchesText(_ query: String) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        return venue.lowercased().contains(needle)
            || vehicle.lowercased().contains(needle)
            || driver.lowercased().contains(needle)
    }
}
