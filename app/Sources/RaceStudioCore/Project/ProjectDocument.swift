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
    public static let currentSchemaVersion = 7

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
    /// The session/setup log sheet — user-authored weather/engine/dimensions/
    /// weights/fuel/gearing metadata (issue 8.17). Added in schema v4; a migrated
    /// pre-8.17 project defaults to an empty ``LogSheet``.
    public var logSheet: LogSheet
    /// The session video attached to this workspace and the sync offset it was
    /// aligned by (issue 9.6), so a reopened project plays the same footage in
    /// step with the cursor. Added in schema v5; a migrated pre-9.6 project has
    /// no attachment. Schema v6 (issue 9.7) adds the clock rate and the sync
    /// status; a migrated v5 attachment runs at rate `1`.
    public var video: VideoAttachment?
    /// The video overlay drawn over the footage — the live HUD and the burned-in
    /// export (issue 9.10), so a reopened workspace shows the layout it was left
    /// with. Added in schema v7; a migrated pre-9.10 project has no overlay, so
    /// the HUD is off until one is chosen.
    public var overlay: OverlayLayout?

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
        activeLayout: WindowLayout = .timeDistance,
        logSheet: LogSheet = LogSheet(),
        video: VideoAttachment? = nil,
        overlay: OverlayLayout? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionRefs = sessionRefs
        self.layout = layout
        self.selectedLaps = selectedLaps
        self.mathChannels = mathChannels
        self.activeLayout = activeLayout
        self.logSheet = logSheet
        self.video = video
        self.overlay = overlay
    }

    /// `diagnostics`/`warnings` are intentionally omitted — they are transient
    /// load results, so they are never encoded and default to empty on decode.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionRefs, layout, selectedLaps, mathChannels, activeLayout, logSheet, video, overlay
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
            && lhs.logSheet == rhs.logSheet
            && lhs.video == rhs.video
            && lhs.overlay == rhs.overlay
    }
}

extension ProjectDocument {

    /// The warning a load records when the overlay could not be read.
    static let unreadableOverlayWarning = "unreadable video overlay; opened with the overlay off"

    /// Decodes every field exactly as the synthesized conformance would, except
    /// the 9.10 ``overlay``: it is cosmetic next to the analysis it sits on, so a
    /// value that isn't a layout at all costs only the overlay — the workspace
    /// opens with it off and records ``unreadableOverlayWarning`` — rather than
    /// making the whole project unopenable. (A layout's own fields are already
    /// read leniently; see ``OverlayLayout``.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
                  sessionRefs: try container.decode([SessionRef].self, forKey: .sessionRefs),
                  layout: try container.decode(AnalysisLayout.self, forKey: .layout),
                  selectedLaps: try container.decode([LapSelection].self, forKey: .selectedLaps),
                  mathChannels: try container.decode([MathChannelDef].self, forKey: .mathChannels),
                  activeLayout: try container.decode(WindowLayout.self, forKey: .activeLayout),
                  logSheet: try container.decode(LogSheet.self, forKey: .logSheet),
                  video: try container.decodeIfPresent(VideoAttachment.self, forKey: .video))
        do {
            overlay = try container.decodeIfPresent(OverlayLayout.self, forKey: .overlay)
        } catch {
            warnings.append(Self.unreadableOverlayWarning)
        }
    }
}
