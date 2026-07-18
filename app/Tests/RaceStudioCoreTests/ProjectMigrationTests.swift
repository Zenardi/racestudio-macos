import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the versioned-schema migration path of the project document
/// (issue 5.4): a v1 `.rsproj` upgrades forward to the current shape, and an
/// unknown/newer version is refused rather than corrupting state.
@Suite struct ProjectMigrationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore {
        ProjectStore(validator: FakeExpressionValidator())
    }

    /// The committed v1 golden (`fixtures/golden/sample.v1.rsproj`).
    private func v1GoldenURL() -> URL {
        FixtureLoader.fixturesDir()
            .appendingPathComponent("golden")
            .appendingPathComponent("sample.v1.rsproj")
    }

    @Test func test_v1_document_migrates_forward() throws {
        let loaded = try store().load(from: v1GoldenURL())

        // v1 had no per-channel `unit`; migration fills it with "" and stamps the
        // current schema version — otherwise value-equal to the modern document.
        let expected = ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: [SessionRef(id: "fuji_0033_abc123", displayName: "Fuji Practice")],
            layout: AnalysisLayout(
                panes: [Pane(channelNames: ["Speed", "RPM"]), Pane(channelNames: ["GPS Speed"])],
                xAxisMode: .distance),
            selectedLaps: [LapSelection(sessionID: "fuji_0033_abc123", lapIndices: [11, 12])],
            mathChannels: [MathChannelDef(name: "AccelMag", unit: "", expression: "sqrt(Ax*Ax + Ay*Ay)")])

        #expect(loaded == expected)
        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
    }

    @Test func test_unknown_version_returns_unsupported() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("future.rsproj")
        // A newer schema than this build understands.
        try Data(#"{"schemaVersion": 999}"#.utf8).write(to: url)

        #expect(throws: ProjectError.unsupportedVersion) { try self.store().load(from: url) }
    }

    @Test func test_non_positive_version_is_corrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.rsproj")
        // A version below 1 is not a real schema — corruption, not a newer build.
        try Data(#"{"schemaVersion": 0}"#.utf8).write(to: url)

        #expect(throws: ProjectError.corruptDocument) { try self.store().load(from: url) }
    }
}
