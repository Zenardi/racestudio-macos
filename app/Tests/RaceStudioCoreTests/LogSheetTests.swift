import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the session/setup Log Sheet (issue 8.17): the user-authored metadata
/// ledger (weather, engine, dimensions, weights, fuel, gearing) that persists with
/// the project (`.rsproj`). Covers the value type's defaults/equality and its
/// round-trip + forward-migration through the 5.4 `ProjectStore`.
@Suite struct LogSheetTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    /// A fully-populated sheet touching every group, so a round-trip that drops any
    /// field fails.
    private func populatedSheet() -> LogSheet {
        LogSheet(
            weather: LogSheet.Weather(airTempC: 21.5, trackTempC: 34, conditions: "Dry", humidityPercent: 40),
            engine: LogSheet.Engine(make: "Honda K20", displacementCC: 1998, notes: "fresh rebuild"),
            dimensions: LogSheet.Dimensions(wheelbaseMM: 2300, frontTrackMM: 1500, rearTrackMM: 1480),
            weights: LogSheet.Weights(totalKg: 620, frontKg: 300, rearKg: 320),
            fuel: LogSheet.Fuel(capacityL: 45, startLevelL: 30, type: "98 RON"),
            gearing: LogSheet.Gearing(finalDrive: "4.10", primaryDrive: "2.00", ratios: ["2.80", "1.90", "1.40"]),
            notes: "baseline setup")
    }

    private func document(logSheet: LogSheet) -> ProjectDocument {
        ProjectDocument(
            sessionRefs: [SessionRef(id: "s1", displayName: "Fuji")],
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed"])], xAxisMode: .time),
            selectedLaps: [LapSelection(sessionID: "s1", lapIndices: [0])],
            mathChannels: [],
            logSheet: logSheet)
    }

    // MARK: - Value type

    @Test func test_a_fresh_log_sheet_is_empty() {
        #expect(LogSheet().isEmpty)
    }

    @Test func test_a_populated_log_sheet_is_not_empty() {
        #expect(!populatedSheet().isEmpty)
    }

    @Test func test_document_defaults_to_an_empty_log_sheet() {
        #expect(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)).logSheet == LogSheet())
    }

    // MARK: - Persistence (acceptance: edited fields persist with the .rsproj)

    @Test func test_every_log_sheet_group_roundtrips_through_save_load() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.rsproj")
        let sheet = populatedSheet()

        try store().save(document(logSheet: sheet), to: url)
        let loaded = try store().load(from: url)

        #expect(loaded.logSheet == sheet)
        // Spot-check one field per group survived the JSON hop.
        #expect(loaded.logSheet.weather.conditions == "Dry")
        #expect(loaded.logSheet.engine.displacementCC == 1998)
        #expect(loaded.logSheet.dimensions.wheelbaseMM == 2300)
        #expect(loaded.logSheet.weights.totalKg == 620)
        #expect(loaded.logSheet.fuel.type == "98 RON")
        #expect(loaded.logSheet.gearing.ratios == ["2.80", "1.90", "1.40"])
    }

    @Test func test_documents_differing_only_in_the_log_sheet_are_not_equal() {
        #expect(document(logSheet: populatedSheet()) != document(logSheet: LogSheet()))
    }

    @Test func test_the_rsproj_json_carries_a_log_sheet_object() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.rsproj")

        try store().save(document(logSheet: populatedSheet()), to: url)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["logSheet"] != nil)
    }

    // MARK: - Forward migration

    @Test func test_a_pre_8_17_v3_document_migrates_forward_with_an_empty_log_sheet() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v3.rsproj")
        // A pre-8.17 v3 document has an activeLayout but no `logSheet` key.
        let v3 = """
        {
          "schemaVersion": 3,
          "sessionRefs": [{"id": "s1", "displayName": "Fuji"}],
          "layout": {"panes": [{"channelNames": ["Speed"]}], "xAxisMode": "distance"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [2]}],
          "mathChannels": [],
          "activeLayout": "trackMap"
        }
        """
        try Data(v3.utf8).write(to: url)

        let loaded = try store().load(from: url)

        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.logSheet == LogSheet(), "a migrated v3 project opens with an empty log sheet")
        #expect(loaded.activeLayout == .trackMap, "the v3 active layout is carried over unchanged")
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [2])])
    }
}

/// Tests for `LogSheetModel` (issue 8.17): the editable live home for the log
/// sheet, owned by the analysis window like the 8.8 math-channels manager.
@MainActor
@Suite struct LogSheetModelTests {

    @Test func test_a_new_model_starts_with_an_empty_sheet() {
        #expect(LogSheetModel().sheet.isEmpty)
    }

    @Test func test_init_seeds_the_sheet() {
        let model = LogSheetModel(sheet: LogSheet(notes: "seed"))
        #expect(model.sheet.notes == "seed")
    }

    @Test func test_apply_replaces_the_whole_sheet() {
        let model = LogSheetModel()
        model.apply(LogSheet(notes: "loaded"))
        #expect(model.sheet.notes == "loaded")
        #expect(!model.sheet.isEmpty)
    }

    @Test func test_sheet_is_directly_mutable_for_form_binding() {
        // The Log Sheet form binds two-way onto `sheet`, so a field edit sticks.
        let model = LogSheetModel()
        model.sheet.weather.conditions = "Wet"
        #expect(model.sheet.weather.conditions == "Wet")
    }
}
