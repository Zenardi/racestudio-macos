import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for persisting the window's active layout in a project (issue 8.13): the
/// schema-v3 `activeLayout` field round-trips, is part of value-equality, and a
/// pre-8.13 v2 document migrates forward defaulting to the Time/Distance layout.
@Suite struct ProjectActiveLayoutTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-active-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    private func document(activeLayout: WindowLayout) -> ProjectDocument {
        ProjectDocument(
            sessionRefs: [SessionRef(id: "s1", displayName: "Fuji")],
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed"])], xAxisMode: .time),
            selectedLaps: [LapSelection(sessionID: "s1", lapIndices: [0])],
            mathChannels: [],
            activeLayout: activeLayout)
    }

    @Test func test_active_layout_roundtrips_through_save_load() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.rsproj")
        let doc = document(activeLayout: .trackMap)

        try store().save(doc, to: url)
        let loaded = try store().load(from: url)

        #expect(loaded.activeLayout == .trackMap)
        #expect(loaded == doc)
    }

    @Test func test_active_layout_defaults_to_time_distance() {
        #expect(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)).activeLayout == .timeDistance)
    }

    @Test func test_documents_differing_only_in_active_layout_are_not_equal() {
        #expect(document(activeLayout: .trackMap) != document(activeLayout: .histogram))
    }

    @Test func test_v2_document_migrates_forward_defaulting_the_active_layout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v2.rsproj")
        // A pre-8.13 v2 document has no `activeLayout` key.
        let v2 = """
        {
          "schemaVersion": 2,
          "sessionRefs": [{"id": "s1", "displayName": "Fuji"}],
          "layout": {"panes": [{"channelNames": ["Speed", "RPM"]}], "xAxisMode": "distance"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [3, 4]}],
          "mathChannels": [{"name": "AccelMag", "unit": "g", "expression": "sqrt(Ax*Ax + Ay*Ay)"}]
        }
        """
        try Data(v2.utf8).write(to: url)

        let loaded = try store().load(from: url)

        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.activeLayout == .timeDistance, "a migrated v2 project opens on Time/Distance")
        #expect(loaded.layout.panes == [Pane(channelNames: ["Speed", "RPM"])], "the rest migrates unchanged")
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [3, 4])])
    }
}
