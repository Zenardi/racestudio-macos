import Foundation

/// Persist the plot's X-axis domain (issue 4.1's ``XAxisMode``) in project files
/// (issue 5.4). The enum has no associated values, so it is already `Equatable`;
/// this adds `Codable` (via its `String` raw value) for on-disk storage.
extension XAxisMode: Codable {}

/// The analysis view layout persisted in a project/workspace file (issue 5.4):
/// the ordered chart panes and the shared X-axis domain.
public struct AnalysisLayout: Codable, Equatable, Sendable {
    /// The chart panes, top-to-bottom.
    public var panes: [Pane]
    /// Whether the shared X axis plots against time or track distance.
    public var xAxisMode: XAxisMode

    public init(panes: [Pane], xAxisMode: XAxisMode) {
        self.panes = panes
        self.xAxisMode = xAxisMode
    }
}

/// One chart pane and the channels assigned to it (by name).
public struct Pane: Codable, Equatable, Sendable {
    /// The channels drawn in this pane, in order.
    public var channelNames: [String]

    public init(channelNames: [String]) {
        self.channelNames = channelNames
    }
}

/// A per-session lap selection (which laps are shown/overlaid). `lapIndices` are
/// clamped to the session's lap range when the project is loaded.
public struct LapSelection: Codable, Equatable, Sendable {
    /// The content id of the session these laps belong to.
    public var sessionID: String
    /// The selected lap indices.
    public var lapIndices: [Int]
    /// The reference lap index the panels compare against, if any (issue 8.13).
    /// Optional so a pre-8.13 project (no reference key) decodes to `nil` and the
    /// window promotes the first selected lap on restore.
    public var reference: Int?

    public init(sessionID: String, lapIndices: [Int], reference: Int? = nil) {
        self.sessionID = sessionID
        self.lapIndices = lapIndices
        self.reference = reference
    }
}

/// A reference from a project to a session in the 5.3 library, by content id.
///
/// `resolved` is transient — recomputed when the project is loaded against the
/// current library — so a project that outlives a session keeps the reference
/// (flagged unresolved) rather than dropping it, and re-importing the file
/// restores it. It is therefore not persisted.
public struct SessionRef: Codable, Equatable, Sendable {
    /// The referenced session's stable content id (see `SessionIndex`).
    public var id: String
    /// A human-readable label shown even when the session is unavailable.
    public var displayName: String
    /// Whether `id` currently resolves to a session in the library.
    public var resolved: Bool = true

    public init(id: String, displayName: String, resolved: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.resolved = resolved
    }

    /// `resolved` is intentionally omitted — it is transient, library-derived
    /// state recomputed on load, so it is never encoded.
    private enum CodingKeys: String, CodingKey {
        case id, displayName
    }

    /// Value-equality compares the persisted identity only; `resolved` is
    /// transient load state, so two refs to the same session are equal whether or
    /// not the library currently resolves them (keeps save/load round-tripping).
    public static func == (lhs: SessionRef, rhs: SessionRef) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName
    }
}
