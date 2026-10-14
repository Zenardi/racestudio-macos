import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the Split Times splits saved with the workspace (issue 9.20):
/// ``ProjectDocument/splits`` is in the `.rsproj` from schema **v9** and reopens
/// exactly, a v8 workspace opens with the default splits, and an unreadable
/// value costs only the splits.
///
/// Every fixture here is synthetic.
@Suite struct ProjectDocumentSplitsMigrationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rssplits-v9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    /// A workspace as a v8 build wrote it, plus `extra` keys.
    private func project(version: Int, extra: String = "") -> String {
        """
        {
          "schemaVersion": \(version),
          "sessionRefs": [{"id": "s1", "displayName": "Interlagos"}],
          "layout": {"panes": [{"channelNames": ["GPS Speed"]}], "xAxisMode": "time"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [3]}],
          "mathChannels": [],
          "activeLayout": "splitTimes",
          "logSheet": {
            "weather": {"conditions": "Dry"},
            "engine": {"make": "", "notes": ""},
            "dimensions": {},
            "weights": {},
            "fuel": {"type": ""},
            "gearing": {"finalDrive": "", "primaryDrive": "", "ratios": []},
            "notes": ""
          },
          "overlay": {"name": "Mine", "widgets": []},
          "videoData": {"side": 0.4}\(extra)
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

    /// Five splits, the third renamed and a corner.
    private var splits: SplitLayout {
        SplitLayout.even(base: SplitReportModel.baseResolution, count: 5)
            .renaming(2, to: "Hairpin")
            .settingKind(2, to: .corner)
    }

    // MARK: - v9

    /// Save → reopen restores the splits exactly, and the file is stamped v9.
    @Test func test_v9_round_trip_keeps_the_splits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("splits.rsproj")
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), splits: splits)

        try store().save(document, to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let loaded = try store().load(from: url)

        #expect(json?["schemaVersion"] as? Int == 9)
        #expect(json?["splits"] != nil)
        #expect(loaded.splits == splits)
        #expect(loaded == document)
    }

    /// A workspace without splits saves none, and reads back the same.
    @Test func test_a_workspace_without_splits_round_trips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("none.rsproj")
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time))

        try store().save(document, to: url)

        #expect(try store().load(from: url).splits == nil)
    }

    /// Splits that aren't a layout cost only the splits: the workspace opens
    /// with the default ones and everything else intact.
    @Test(arguments: [#", "splits": [1, 2]"#, #", "splits": {"base": 4, "nextID": 1, "splits": []}"#])
    func test_unreadable_splits_open_the_default(extra: String) throws {
        let loaded = try load(project(version: 9, extra: extra))

        #expect(loaded.splits == nil)
        #expect(loaded.overlay?.name == "Mine")
        #expect(loaded.activeLayout == .splitTimes)
    }

    // MARK: - Older workspaces

    /// A v8 workspace opens at the current schema with the default splits and
    /// everything else it carried.
    @Test func test_a_v8_workspace_opens_with_the_default_splits() throws {
        let loaded = try load(project(version: 8))

        #expect(loaded.splits == nil)
        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.overlay?.name == "Mine")
        #expect(loaded.videoData.fraction(.side) == 0.4)
    }

    /// A v8 file carries no splits even if one is written into it: the key
    /// means nothing at that version.
    @Test func test_a_splits_key_in_a_v8_file_is_ignored() throws {
        let json = try String(data: JSONEncoder().encode(splits), encoding: .utf8) ?? ""

        let loaded = try load(project(version: 8, extra: #", "splits": \#(json)"#))

        #expect(loaded.splits == nil)
    }

    // MARK: - The window

    /// The window's captured workspace carries the splits it is given.
    @MainActor
    @Test func test_the_window_captures_the_splits() {
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "Interlagos", driver: "", session: "", series: "",
                                      logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 20, decimals: 1, sampleCount: 10)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 60, endTimeS: 60)])
        let model = AnalysisWindowModel(session: session, analysis: nil)

        #expect(model.projectDocument(splits: splits).splits == splits)
        #expect(model.projectDocument().splits == nil)
    }
}
