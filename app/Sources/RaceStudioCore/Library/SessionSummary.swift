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
    /// Driver name.
    public let driver: String
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
        isAvailable: Bool
    ) {
        self.id = id
        self.venue = venue
        self.date = date
        self.vehicle = vehicle
        self.driver = driver
        self.lapCount = lapCount
        self.bestLap = bestLap
        self.sourceURL = sourceURL
        self.importedAt = importedAt
        self.isAvailable = isAvailable
    }

    /// `isAvailable` is intentionally omitted — it is transient, filesystem-derived
    /// state (see above), so it is never encoded and defaults on decode.
    private enum CodingKeys: String, CodingKey {
        case id, venue, date, vehicle, driver, lapCount, bestLap, sourceURL, importedAt
    }
}
