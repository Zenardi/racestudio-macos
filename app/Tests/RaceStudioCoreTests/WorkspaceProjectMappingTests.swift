import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the `AnalysisWindowModel` ↔ `ProjectDocument` mapping (issue 8.13):
/// capturing the window's selection / active layout / math channels into a
/// persistable document, and restoring them back — including the full
/// save→load→restore round-trip through the 5.4 `ProjectStore`.
@MainActor
@Suite struct WorkspaceProjectMappingTests {

    // MARK: - Fixture (no logic — fixed, index-derived data)

    private func channel(_ name: String) -> Channel {
        Channel(name: name, unit: "", sampleRateHz: 10, decimals: 0, sampleCount: 10)
    }

    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
         Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10),
         Lap(index: 2, startTimeS: 10, durationS: 5, endTimeS: 15)]
    }

    private func makeSession() -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "SFJ", track: "Fuji", driver: "CMD",
                                      session: "Practice", series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [channel("Speed"), channel("RPM"), channel("GPS Speed")],
            laps: laps())
    }

    private func makeModel() -> AnalysisWindowModel {
        AnalysisWindowModel(session: makeSession(), analysis: nil)
    }

    private let mathChannels = [MathChannelDef(name: "AccelMag", unit: "g", expression: "sqrt(Ax*Ax + Ay*Ay)")]

    // MARK: - Capture

    @Test func test_document_captures_selected_channels_as_a_pane_in_order() {
        let model = makeModel()
        model.setSelection(channelNames: ["RPM", "Speed"], lapIndices: [])
        let document = model.projectDocument()
        #expect(document.layout.panes == [Pane(channelNames: ["RPM", "Speed"])])
    }

    @Test func test_document_captures_selected_laps_under_the_session_content_id() {
        let model = makeModel()
        model.setSelection(channelNames: ["Speed"], lapIndices: [0, 2], reference: 2)
        let document = model.projectDocument()
        let id = SessionIndex.contentID(for: makeSession())
        #expect(document.selectedLaps == [LapSelection(sessionID: id, lapIndices: [0, 2], reference: 2)])
        #expect(document.sessionRefs.first?.id == id)
    }

    @Test func test_document_captures_active_layout_and_math_channels() {
        let model = makeModel()
        model.select(layout: .trackMap)
        let document = model.projectDocument(mathChannels: mathChannels)
        #expect(document.activeLayout == .trackMap)
        #expect(document.mathChannels == mathChannels)
    }

    @Test func test_document_defaults_to_an_empty_log_sheet() {
        #expect(makeModel().projectDocument().logSheet.isEmpty)
    }

    @Test func test_document_captures_the_supplied_log_sheet() {
        // The log sheet is owned outside the window (like math channels) and passed in.
        let document = makeModel().projectDocument(logSheet: LogSheet(notes: "captured"))
        #expect(document.logSheet.notes == "captured")
    }

    // MARK: - Restore

    @Test func test_restore_reapplies_channels_laps_reference_and_active_layout() {
        let source = makeModel()
        source.setSelection(channelNames: ["GPS Speed", "Speed"], lapIndices: [1, 2], reference: 2)
        source.select(layout: .scatter)
        let document = source.projectDocument()

        let restored = makeModel()
        restored.restore(from: document)

        #expect(restored.selection.channels.map(\.name) == ["GPS Speed", "Speed"])
        #expect(restored.selection.laps.selected == [LapID(1), LapID(2)])
        #expect(restored.selection.laps.reference == LapID(2))
        #expect(restored.activeLayout == .scatter)
    }

    @Test func test_restore_skips_channels_absent_from_this_session() {
        let model = makeModel()
        let document = ProjectDocument(
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed", "Ghost", "RPM"])], xAxisMode: .time))
        model.restore(from: document)
        #expect(model.selection.channels.map(\.name) == ["Speed", "RPM"], "the missing 'Ghost' channel is dropped")
    }

    @Test func test_restore_drops_lap_indices_outside_the_session() {
        let id = SessionIndex.contentID(for: makeSession())
        let model = makeModel()
        let document = ProjectDocument(
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed"])], xAxisMode: .time),
            selectedLaps: [LapSelection(sessionID: id, lapIndices: [1, 9])])
        model.restore(from: document)
        #expect(model.selection.laps.selected == [LapID(1)], "lap 9 does not exist and is dropped")
    }

    // MARK: - Round-trip through ProjectStore (the 5.4 persistence)

    @Test func test_save_load_restore_roundtrips_the_workspace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspace.rsproj")

        let source = makeModel()
        source.setSelection(channelNames: ["Speed", "GPS Speed"], lapIndices: [0, 1], reference: 1)
        source.select(layout: .histogram)
        let document = source.projectDocument(mathChannels: mathChannels)

        let store = ProjectStore(validator: FakeExpressionValidator())
        try store.save(document, to: url)
        let loaded = try store.load(from: url)
        #expect(loaded == document, "the 5.4 document round-trips value-equal")

        let restored = makeModel()
        restored.restore(from: loaded)
        #expect(restored.selection == source.selection, "the window's selection is fully restored")
        #expect(restored.activeLayout == source.activeLayout)
    }
}
