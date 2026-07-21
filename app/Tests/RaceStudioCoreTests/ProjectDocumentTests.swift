import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the project/workspace document + store (issue 5.4) — versioned,
/// atomic save/load of analysis layouts, selected laps, and math channels.
///
/// Math-channel validation is injected (`FakeExpressionValidator`) so this suite
/// exercises the pure `RaceStudioCore` load/validate/clamp logic without the FFI;
/// the real FFI parser path is covered by `ProjectFFIValidatorTests`.
@Suite struct ProjectDocumentTests {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleDocument(
        mathChannels: [MathChannelDef] = [
            MathChannelDef(name: "AccelMag", unit: "g", expression: "sqrt(Ax*Ax + Ay*Ay)")
        ],
        selectedLaps: [LapSelection] = [LapSelection(sessionID: "s1", lapIndices: [0, 1, 2])]
    ) -> ProjectDocument {
        ProjectDocument(
            sessionRefs: [SessionRef(id: "s1", displayName: "Fuji Practice")],
            layout: AnalysisLayout(
                panes: [Pane(channelNames: ["Speed", "RPM"]), Pane(channelNames: ["GPS Speed"])],
                xAxisMode: .distance),
            selectedLaps: selectedLaps,
            mathChannels: mathChannels)
    }

    private func store(invalid: Set<String> = []) -> ProjectStore {
        ProjectStore(validator: FakeExpressionValidator(invalid: invalid))
    }

    // MARK: - round-trip & shape

    @Test func test_save_load_roundtrip_is_value_equal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        let document = sampleDocument()

        let store = store()
        try store.save(document, to: url)
        let loaded = try store.load(from: url)

        #expect(loaded == document)
    }

    @Test func test_file_has_schema_version_and_rsproj_shape() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.\(ProjectStore.fileExtension)")

        try store().save(sampleDocument(), to: url)

        #expect(ProjectStore.fileExtension == "rsproj")
        #expect(url.pathExtension == "rsproj")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ProjectDocument.currentSchemaVersion)
        for key in ["sessionRefs", "layout", "selectedLaps", "mathChannels", "activeLayout", "logSheet"] {
            #expect(object[key] != nil)
        }
    }

    // MARK: - math-channel validation on load

    @Test func test_math_channel_expression_revalidated_on_load() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        let document = sampleDocument(mathChannels: [
            MathChannelDef(name: "A", unit: "g", expression: "Ax*2"),
            MathChannelDef(name: "B", unit: "", expression: "Ay+1")
        ])
        let validator = FakeExpressionValidator()
        let store = ProjectStore(validator: validator)
        try store.save(document, to: url)

        _ = try store.load(from: url)

        // Every stored expression was re-parsed on load.
        #expect(validator.validated.sorted() == ["Ax*2", "Ay+1"])
    }

    @Test func test_invalid_math_channel_reports_error_without_aborting_load() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        let document = sampleDocument(mathChannels: [
            MathChannelDef(name: "Good", unit: "g", expression: "Ax*2"),
            MathChannelDef(name: "Bad", unit: "", expression: "Ax +* 2")
        ])
        let store = store(invalid: ["Ax +* 2"])
        try store.save(document, to: url)

        let loaded = try store.load(from: url)

        // Load did not abort: both channels survive …
        #expect(loaded.mathChannels.map(\.name) == ["Good", "Bad"])
        // … and only the invalid one is flagged with a typed error.
        #expect(loaded.diagnostics == [.invalidMathChannel(name: "Bad")])
    }

    // MARK: - atomicity, corruption

    private enum TestCrash: Error { case interrupted }

    @Test func test_atomic_save_survives_interruption_and_corrupt_loads_typed_error() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")

        // A committed, good document.
        try store().save(sampleDocument(), to: url)

        // A save interrupted before it commits maps to ioFailure and leaves the
        // prior file intact (never truncated).
        let crashing = ProjectStore(
            validator: FakeExpressionValidator(), write: { _, _ in throw TestCrash.interrupted })
        #expect(throws: ProjectError.ioFailure) {
            try crashing.save(self.sampleDocument(mathChannels: []), to: url)
        }
        #expect(try store().load(from: url).mathChannels.map(\.name) == ["AccelMag"])

        // A garbage file loads to a typed corruptDocument, never a crash.
        try Data("{ not a project ".utf8).write(to: url)
        #expect(throws: ProjectError.corruptDocument) { try self.store().load(from: url) }
    }

    @Test func test_load_of_missing_file_throws_io_failure() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).rsproj")

        #expect(throws: ProjectError.ioFailure) { try self.store().load(from: url) }
    }

    @Test func test_current_version_with_malformed_body_is_corrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        // Valid schemaVersion, but the body is the wrong shape.
        try Data(#"{"schemaVersion": 2, "sessionRefs": "not-an-array"}"#.utf8).write(to: url)

        #expect(throws: ProjectError.corruptDocument) { try self.store().load(from: url) }
    }

    @Test func test_v1_body_malformed_is_corrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        // Declares v1 but the payload can't decode as a v1 document.
        try Data(#"{"schemaVersion": 1, "mathChannels": 123}"#.utf8).write(to: url)

        #expect(throws: ProjectError.corruptDocument) { try self.store().load(from: url) }
    }

    // MARK: - reference resolution & lap clamping

    @Test func test_unresolved_session_reference_is_retained_and_flagged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try store().save(sampleDocument(), to: url)

        // The library knows some other session, but not this project's "s1".
        let loaded = try store().load(from: url, library: LibraryContext(lapCountsByID: ["other": 5]))

        #expect(loaded.sessionRefs.map(\.id) == ["s1"])          // retained
        #expect(loaded.sessionRefs.first?.resolved == false)     // flagged unresolved
    }

    @Test func test_out_of_range_lap_selection_is_clamped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        let document = sampleDocument(
            selectedLaps: [LapSelection(sessionID: "s1", lapIndices: [-1, 0, 1, 5, 2])])
        try store().save(document, to: url)

        // Session "s1" has only 3 laps (valid indices 0…2).
        let loaded = try store().load(from: url, library: LibraryContext(lapCountsByID: ["s1": 3]))

        #expect(loaded.selectedLaps.first?.lapIndices == [0, 1, 2])  // out-of-range dropped
        #expect(!loaded.warnings.isEmpty)                            // a warning was recorded
    }

    @Test func test_zero_lap_count_clamps_selection_to_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try store().save(
            sampleDocument(selectedLaps: [LapSelection(sessionID: "s1", lapIndices: [0, 1, 2])]), to: url)

        // Session "s1" currently has zero laps — every index is out of range.
        let loaded = try store().load(from: url, library: LibraryContext(lapCountsByID: ["s1": 0]))

        #expect(loaded.selectedLaps.first?.lapIndices == [])
        #expect(!loaded.warnings.isEmpty)
    }

    @Test func test_empty_library_marks_all_references_unresolved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try store().save(sampleDocument(), to: url)

        // An explicitly empty library (not nil) resolves against zero sessions,
        // so every reference is flagged unresolved — but retained.
        let loaded = try store().load(from: url, library: LibraryContext())

        #expect(loaded.sessionRefs.allSatisfy { !$0.resolved })
        #expect(loaded.sessionRefs.map(\.id) == ["s1"])
    }

    // MARK: - persistence hygiene

    @Test func test_transient_fields_are_not_persisted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try store().save(sampleDocument(), to: url)

        // Load-time state (diagnostics / warnings / resolved) is never serialised.
        let json = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(!json.contains("diagnostics"))
        #expect(!json.contains("warnings"))
        #expect(!json.contains("resolved"))
    }

    @Test func test_real_atomic_save_overwrites_cleanly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        let store = store()  // the real atomic Data.write path

        try store.save(sampleDocument(mathChannels: [
            MathChannelDef(name: "A", unit: "", expression: "Ax"),
            MathChannelDef(name: "B", unit: "", expression: "Ay")
        ]), to: url)
        try store.save(sampleDocument(mathChannels: []), to: url)  // overwrite, smaller

        // The target holds exactly the new document — no merged/partial content …
        #expect(try store.load(from: url).mathChannels.isEmpty)
        // … and the atomic write left no temp sidecar behind.
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["project.rsproj"])
    }
}
