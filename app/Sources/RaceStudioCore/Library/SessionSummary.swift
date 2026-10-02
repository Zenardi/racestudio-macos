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
    /// A user-chosen name shown in place of ``venue``, or `nil` to use the decoded
    /// value. A logger stamps the venue from whatever track was last configured on
    /// it, so the decoded name is often wrong — one of two stints at the same
    /// circuit can arrive named after a different track entirely. The override is
    /// display-only: ``venue`` stays the facet/filter key, so a renamed session
    /// still groups with its circuit.
    public var customName: String?
    /// The stable id of the circuit auto-recognized from this session's GPS trace,
    /// or `nil` when none matched. Stamped at import; the key a user-chosen **track**
    /// name is stored against.
    public var trackID: String?
    /// The user's name for ``trackID``, denormalized from the index so a row can
    /// render its own title. Maintained by ``SessionIndex/renameTrack(id:to:)``.
    public var trackNickname: String?
    /// The recognized circuit's name including its layout (e.g. `"Kartódromo San
    /// Marino — Layout 2"`), or `nil` when no track matched. Stamped at import so
    /// the library can show which circuit a session is from without re-decoding it.
    public var trackLabel: String?
    /// The direction the recognized layout is driven, or `nil` when no track matched
    /// or the database does not record it.
    public var trackDirection: TrackDirection?
    /// The garage kart this session was driven on (``Kart/id``), or `nil` when
    /// none is assigned. User-authored, so a re-import keeps it.
    public var kartID: String?
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
        isAvailable: Bool, championship: String = "", comment: String = "", logger: String = "",
        customName: String? = nil, trackID: String? = nil, trackNickname: String? = nil,
        trackLabel: String? = nil, trackDirection: TrackDirection? = nil, kartID: String? = nil
    ) {
        self.kartID = kartID
        self.id = id
        self.venue = venue
        self.customName = customName
        self.trackID = trackID
        self.trackNickname = trackNickname
        self.trackLabel = trackLabel
        self.trackDirection = trackDirection
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
             lapCount, bestLap, sourceURL, importedAt, customName, trackID, trackNickname,
             trackLabel, trackDirection, kartID
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
        // Optional on disk: a library written before renaming existed has no key.
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        trackID = try container.decodeIfPresent(String.self, forKey: .trackID)
        trackNickname = try container.decodeIfPresent(String.self, forKey: .trackNickname)
        trackLabel = try container.decodeIfPresent(String.self, forKey: .trackLabel)
        trackDirection = try container.decodeIfPresent(TrackDirection.self, forKey: .trackDirection)
        kartID = try container.decodeIfPresent(String.self, forKey: .kartID)
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

public extension SessionSummary {
    /// Shown as the title of a session that has neither a user-chosen name nor a
    /// decoded venue, so a row is never blank.
    static let untitledText = "Unknown venue"

    /// The title to show for this session, most specific name first: the name the
    /// user gave *this session*, else the name they gave *this track*, else the
    /// decoded ``venue``, else ``untitledText``.
    ///
    /// The track name sits between the two because it is the fix for a logger that
    /// mis-stamps the venue — naming the circuit once retitles every session
    /// recorded there — while a session-specific name ("wet session") is still more
    /// specific than the circuit's.
    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        if let trackNickname, !trackNickname.isEmpty { return trackNickname }
        return venue.isEmpty ? SessionSummary.untitledText : venue
    }
}

public extension SessionSummary {
    /// The recognized circuit and the way round it is driven, e.g.
    /// `"Kartódromo San Marino — Layout 2 · Counter-clockwise"`. `nil` when no track
    /// matched, in which case splits come from the logged beacons instead.
    var trackSummary: String? {
        guard let trackLabel else { return nil }
        guard let trackDirection else { return trackLabel }
        return "\(trackLabel) · \(trackDirection.title)"
    }
}

extension SessionSummary {
    /// Case-insensitive substring match across the custom name, venue, vehicle, and
    /// driver — the library's free-text search (issue 5.3). An empty query matches
    /// everything. Shared by ``SessionIndex/search(_:)`` and the browser's scoped
    /// search so they agree on what "matches the text" means.
    ///
    /// The custom name is included because renaming is how a user makes a
    /// mis-stamped session findable; searching only the decoded fields would hide
    /// the very session they just named.
    func matchesText(_ query: String) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        return venue.lowercased().contains(needle)
            || vehicle.lowercased().contains(needle)
            || driver.lowercased().contains(needle)
            || (customName?.lowercased().contains(needle) ?? false)
            || (trackNickname?.lowercased().contains(needle) ?? false)
    }
}
