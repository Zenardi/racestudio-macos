import Foundation

/// A project/workspace document (issue 5.4): the persisted analysis session —
/// which sessions are referenced, the view layout, selected laps, and
/// user-defined math channels — serialised as a versioned `.rsproj` JSON file.
///
/// The schema is explicitly versioned (``schemaVersion``) so older files migrate
/// forward. ``diagnostics`` and ``warnings`` are transient load-time results
/// (invalid math channels, clamped lap selections, unresolved references); they
/// are not persisted, so a clean save/load round-trips value-equal.
public struct ProjectDocument: Codable, Equatable, Sendable {

    /// The schema version this build reads and writes.
    public static let currentSchemaVersion = 3

    /// On-disk schema version of this document.
    public var schemaVersion: Int
    /// Referenced library sessions (by content id).
    public var sessionRefs: [SessionRef]
    /// The analysis view layout.
    public var layout: AnalysisLayout
    /// Per-session selected laps.
    public var selectedLaps: [LapSelection]
    /// User-defined math channels (expression source + metadata).
    public var mathChannels: [MathChannelDef]
    /// The analysis window's active panel/layout, so a reopened project restores
    /// the layout it was saved in (issue 8.13). Added in schema v3; a migrated
    /// pre-8.13 project defaults to ``WindowLayout/timeDistance``.
    public var activeLayout: WindowLayout

    /// Non-fatal, typed issues found during load — e.g.
    /// ``ProjectError/invalidMathChannel(name:)``. Transient (not persisted).
    public var diagnostics: [ProjectError] = []
    /// Human-readable load warnings — e.g. a clamped lap selection or an
    /// unresolved session reference. Transient (not persisted).
    public var warnings: [String] = []

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sessionRefs: [SessionRef] = [],
        layout: AnalysisLayout,
        selectedLaps: [LapSelection] = [],
        mathChannels: [MathChannelDef] = [],
        activeLayout: WindowLayout = .timeDistance
    ) {
        self.schemaVersion = schemaVersion
        self.sessionRefs = sessionRefs
        self.layout = layout
        self.selectedLaps = selectedLaps
        self.mathChannels = mathChannels
        self.activeLayout = activeLayout
    }

    /// `diagnostics`/`warnings` are intentionally omitted — they are transient
    /// load results, so they are never encoded and default to empty on decode.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionRefs, layout, selectedLaps, mathChannels, activeLayout
    }

    /// Value-equality compares the persisted content only. `diagnostics` and
    /// `warnings` are transient load results, so a clean save/load round-trips
    /// value-equal regardless of what any given load surfaced.
    public static func == (lhs: ProjectDocument, rhs: ProjectDocument) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.sessionRefs == rhs.sessionRefs
            && lhs.layout == rhs.layout
            && lhs.selectedLaps == rhs.selectedLaps
            && lhs.mathChannels == rhs.mathChannels
            && lhs.activeLayout == rhs.activeLayout
    }
}
