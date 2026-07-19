import Foundation

/// The `AnalysisWindowModel` ↔ `ProjectDocument` mapping (issue 8.13): capture the
/// live window state into a persistable `.rsproj` document, and restore a loaded
/// document back into the window. Save/load itself is the 5.4 `ProjectStore`; this
/// only translates between the window's selection/layout and the document shape.
@MainActor
public extension AnalysisWindowModel {

    /// The session's stable content id (5.3) — the key its selected laps and session
    /// reference are persisted under, so a reopened project re-attaches to the same
    /// session.
    var sessionContentID: String { SessionIndex.contentID(for: session) }

    /// Capture the window's current workspace as a ``ProjectDocument`` (issue 8.13):
    /// the selected channels as one pane (in selection order), the selected lap
    /// indices under the session's content id, the active layout, and the supplied
    /// `mathChannels` (owned by the 8.8 manager, so they are passed in). The result
    /// is what the 5.4 ``ProjectStore`` saves.
    func projectDocument(mathChannels: [MathChannelDef] = []) -> ProjectDocument {
        let id = sessionContentID
        return ProjectDocument(
            sessionRefs: [SessionRef(id: id, displayName: sessionDisplayName)],
            layout: AnalysisLayout(panes: [Pane(channelNames: selection.channels.map(\.name))],
                                   xAxisMode: .time),
            selectedLaps: [LapSelection(sessionID: id, lapIndices: selection.laps.selected.map(\.index),
                                        reference: selection.laps.reference?.index)],
            mathChannels: mathChannels,
            activeLayout: activeLayout)
    }

    /// Restore the window from a loaded ``ProjectDocument`` (issue 8.13): re-select
    /// the persisted channels + laps that exist in this session and switch to the
    /// saved active layout. The lap selection for this session is matched by content
    /// id, falling back to the document's first lap selection when the ids differ
    /// (e.g. a project reopened against a re-imported session). Math channels are
    /// restored by the caller through the 8.8 manager, which owns them.
    func restore(from document: ProjectDocument) {
        let channelNames = document.layout.panes.flatMap(\.channelNames)
        let lapSelection = document.selectedLaps.first { $0.sessionID == sessionContentID }
            ?? document.selectedLaps.first
        setSelection(channelNames: channelNames, lapIndices: lapSelection?.lapIndices ?? [],
                     reference: lapSelection?.reference)
        select(layout: document.activeLayout)
    }

    /// A human-readable label for the session reference: the first non-empty of the
    /// session name / track / vehicle, else a generic fallback.
    private var sessionDisplayName: String {
        let candidates = [session.metadata.session, session.metadata.track, session.metadata.vehicle]
        return candidates.first { !$0.isEmpty } ?? "Session"
    }

    /// Replace the whole selection with the `channelNames` / `lapIndices` present in
    /// this session (issue 8.13's project restore). Channels and laps absent from the
    /// session are skipped and duplicates collapse to their first occurrence, so a
    /// project saved against a different session degrades gracefully. `reference` is
    /// the lap index made reference (ignored when it is not a valid lap). Stale pins /
    /// colour overrides for now-unselected channels are dropped, then the caches
    /// rebuild.
    func setSelection(channelNames: [String], lapIndices: [Int], reference: Int? = nil) {
        var channels: [ChannelID] = []
        var seenChannels = Set<ChannelID>()
        for name in channelNames {
            let id = ChannelID(name)
            guard channelIndexByID[id] != nil, seenChannels.insert(id).inserted else { continue }
            channels.append(id)
        }
        var lapIDs: [LapID] = []
        var seenLaps = Set<LapID>()
        for index in lapIndices {
            let id = LapID(index)
            guard lapByID[id] != nil, seenLaps.insert(id).inserted else { continue }
            lapIDs.append(id)
        }
        let referenceID = reference.map(LapID.init).flatMap { lapByID[$0] != nil ? $0 : nil }
        selection = AnalysisSelection(channels: channels,
                                      laps: LapSelectionModel(selected: lapIDs, reference: referenceID))
        pinnedChannels.removeAll { !channels.contains($0) }
        if let override = colorChannelOverride, !channels.contains(override) { colorChannelOverride = nil }
        rebuildSelectionData()
    }

    /// Reorder the selected laps so the StoryBoard drag (issue 8.13) reflects in
    /// every panel: move the lap at `source` to `destination`, then rebuild the
    /// readout grid columns and the lap overlay to the new order. The reference lap
    /// is preserved.
    func reorderSelectedLap(from source: Int, to destination: Int) {
        selection.moveLap(from: source, to: destination)
        rebuildReadoutTable()
        rebuildOverlay()
    }
}
