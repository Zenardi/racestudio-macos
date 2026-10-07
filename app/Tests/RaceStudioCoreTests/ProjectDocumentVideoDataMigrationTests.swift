import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the Video + Data pane layout persisted with the workspace (issue
/// 9.12): ``ProjectDocument/videoData`` is saved in the `.rsproj` (schema **v8**)
/// and reopens exactly, while a project saved before it existed (v7, v6, v5)
/// opens with the default layout and everything else it carried intact —
/// including the old Video Review layout, which now opens Video + Data.
///
/// Every fixture here is synthetic; the "bookmark" is the bytes of a made-up path.
@Suite struct ProjectDocumentVideoDataMigrationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsvideodata-v8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    private let bookmark = Data("/tmp/onboard/session-lap.mp4".utf8)

    /// A project as an older build wrote it, at `version`, with a video and —
    /// from v7 — an overlay.
    private func project(version: Int, extra: String = "") -> String {
        let video = version >= 6
            ? #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "lap.mp4", "offset": 2.5, "#
                + #""rate": 1.0001, "status": {"kind": "estimated"}}"#
            : #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "lap.mp4", "offset": 2.5}"#
        let overlay = version >= 7 ? #", "overlay": {"name": "Mine", "widgets": []}"# : ""
        return """
        {
          "schemaVersion": \(version),
          "sessionRefs": [{"id": "s1", "displayName": "Interlagos"}],
          "layout": {"panes": [{"channelNames": ["GPS Speed"]}], "xAxisMode": "time"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [3]}],
          "mathChannels": [],
          "activeLayout": "videoReview",
          "logSheet": {
            "weather": {"conditions": "Dry"},
            "engine": {"make": "", "notes": ""},
            "dimensions": {},
            "weights": {},
            "fuel": {"type": ""},
            "gearing": {"finalDrive": "", "primaryDrive": "", "ratios": []},
            "notes": ""
          },
          "video": \(video)\(overlay)\(extra)
        }
        """
    }

    private func load(_ json: String) throws -> ProjectDocument {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try Data(json.utf8).write(to: url)
        return try store().load(from: url)
    }

    private func roundTrip(_ document: ProjectDocument) throws -> ProjectDocument {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v8.rsproj")
        try store().save(document, to: url)
        return try store().load(from: url)
    }

    /// A pane layout the operator rearranged: a wider side column, no lap list.
    private func rearranged() -> VideoDataPaneLayout {
        var layout = VideoDataPaneLayout.default
        layout.setFraction(0.45, for: .side)
        layout.setVisible(false, for: .lapList)
        return layout
    }

    // MARK: - Older projects open with the default layout

    /// v7, v6 and v5 projects all open — into Video + Data, with the default
    /// pane layout, at the current schema — keeping their video.
    @Test(arguments: [7, 6, 5])
    func test_older_projects_open_with_the_default_pane_layout(version: Int) throws {
        let loaded = try load(project(version: version))

        #expect(loaded.videoData == .default)
        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.activeLayout == .videoReview)
        #expect(loaded.video?.offset == 2.5)
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [3])])
    }

    /// A v7 project keeps its overlay through the migration.
    @Test func test_a_v7_project_keeps_its_overlay() throws {
        let loaded = try load(project(version: 7))

        #expect(loaded.overlay?.name == "Mine")
        #expect(loaded.warnings.isEmpty)
    }

    /// A v7 file carries no pane layout even if one is written into it: the key
    /// means nothing at that version.
    @Test func test_a_pane_layout_key_in_a_v7_file_is_ignored() throws {
        let loaded = try load(project(version: 7, extra: #", "videoData": {"side": 0.6}"#))

        #expect(loaded.videoData == .default)
    }

    // MARK: - v8

    /// Save → reopen restores the rearranged panes exactly.
    @Test func test_v8_round_trip_with_a_pane_layout_is_value_equal() throws {
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), videoData: rearranged())

        let loaded = try roundTrip(document)

        #expect(loaded.videoData == rearranged())
        #expect(loaded == document)
    }

    /// A v8 pane layout that isn't one costs only the panes: they open at the
    /// default, and the rest of the project is untouched.
    @Test func test_an_unreadable_v8_pane_layout_opens_the_default() throws {
        let loaded = try load(project(version: 8, extra: #", "videoData": [1, 2]"#))

        #expect(loaded.videoData == .default)
        #expect(loaded.overlay?.name == "Mine")
        #expect(loaded.warnings.isEmpty)
    }

    /// The schema was bumped for the pane layout: a save is stamped v8 on disk.
    @Test func test_saved_projects_are_stamped_v8() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stamp.rsproj")
        try store().save(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)), to: url)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        #expect(json?["schemaVersion"] as? Int == 8)
        #expect(json?["videoData"] != nil)
    }

    // MARK: - The workspace save path

    @MainActor
    private func windowModel() -> AnalysisWindowModel {
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "Interlagos", driver: "", session: "", series: "",
                                      logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 20, decimals: 1, sampleCount: 10)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 60, endTimeS: 60)])
        return AnalysisWindowModel(session: session, analysis: nil)
    }

    /// The window owns the panel's layout — the default until rearranged — and
    /// a saved document carries it.
    @MainActor
    @Test func test_the_window_owns_the_pane_layout_it_saves() {
        let model = windowModel()
        #expect(model.videoDataPanes == .default)

        model.videoDataPanes = rearranged()

        #expect(model.projectDocument().videoData == rearranged())
    }

    /// Reopening a workspace restores its pane layout into the window.
    @MainActor
    @Test func test_restoring_a_workspace_restores_its_pane_layout() {
        let model = windowModel()

        model.restore(from: ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time),
                                            videoData: rearranged()))
        #expect(model.videoDataPanes == rearranged())

        model.restore(from: ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)))
        #expect(model.videoDataPanes == .default)
    }
}
