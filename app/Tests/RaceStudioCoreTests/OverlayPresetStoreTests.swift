import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``OverlayPresetStore`` (issue 9.10): the user's own overlay presets,
/// kept as JSON in Application Support. Writes are atomic; reading is lenient —
/// a missing file is an empty library, a corrupt one yields the built-ins and a
/// logged warning — so a bad preset file can never block the app. Every test
/// runs in its own temporary directory.
@Suite struct OverlayPresetStoreTests {

    private let en = Locale(identifier: "en")

    /// Collects what the store logs.
    private final class LogSpy: @unchecked Sendable {
        var errors: [OverlayPresetStoreError] = []
    }

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rspresets-\(UUID().uuidString)")
    }

    private func store(_ directory: URL, spy: LogSpy = LogSpy(),
                       write: ((Data, URL) throws -> Void)? = nil) -> OverlayPresetStore {
        OverlayPresetStore(directory: directory, write: write, log: { spy.errors.append($0) })
    }

    private func layout(_ name: String) -> OverlayLayout {
        OverlayLayout(name: name, widgets: [
            OverlayWidget(kind: .speed, frame: NormalizedRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2),
                          anchor: .bottomLeading, units: .imperial)
        ], units: .imperial)
    }

    // MARK: - Round trip

    /// Saved presets come back exactly, from a fresh store on the same folder —
    /// as after a relaunch.
    @Test func test_saved_presets_survive_a_relaunch() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store(dir).save([layout("Wet"), layout("Rental")])

        #expect(store(dir).userPresets() == [layout("Wet"), layout("Rental")])
    }

    /// The menu lists the built-ins first, then the user's presets.
    @Test func test_presets_are_the_built_ins_then_the_users() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store(dir).save([layout("Wet")])

        #expect(store(dir).presets(locale: en) == OverlayPreset.builtIns(locale: en) + [layout("Wet")])
    }

    /// The folder is created on the first save.
    @Test func test_a_missing_directory_is_created() throws {
        let dir = makeTempDir().appendingPathComponent("nested/RaceStudio")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

        try store(dir).save([layout("Wet")])

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("OverlayPresets.json").path))
    }

    /// By default the library lives in Application Support, beside the session library.
    @Test func test_the_default_location_is_application_support() {
        let store = OverlayPresetStore()

        #expect(store.fileURL.lastPathComponent == "OverlayPresets.json")
        #expect(store.fileURL.deletingLastPathComponent().lastPathComponent == "RaceStudio")
        #expect(store.fileURL.path.contains("Application Support"))
    }

    // MARK: - Lenient reading

    /// No file yet is an empty library — nothing logged.
    @Test func test_a_missing_file_is_an_empty_library() {
        let spy = LogSpy()
        let empty = store(makeTempDir(), spy: spy)

        #expect(empty.userPresets().isEmpty)
        #expect(empty.presets(locale: en) == OverlayPreset.builtIns(locale: en))
        #expect(spy.errors.isEmpty)
    }

    /// A corrupt file yields the built-ins and a logged warning, never a failure.
    @Test func test_a_corrupt_file_yields_the_built_ins_and_a_warning() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        let presets = store(dir, spy: spy).presets(locale: en)

        #expect(presets == OverlayPreset.builtIns(locale: en))
        #expect(spy.errors == [.corruptFile])
    }

    /// A library file with no preset list is an empty library, not a corrupt one.
    @Test func test_a_file_without_presets_is_an_empty_library() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        #expect(store(dir, spy: spy).userPresets().isEmpty)
        #expect(spy.errors.isEmpty)
    }

    /// With the production log, a corrupt file still only costs the user presets.
    @Test func test_the_default_log_never_blocks_loading() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))

        #expect(OverlayPresetStore(directory: dir).presets(locale: en) == OverlayPreset.builtIns(locale: en))
    }

    /// One preset this build can't read is skipped; the rest load.
    @Test func test_an_unreadable_preset_is_skipped() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "presets": [42, {"name": "Wet"}, "x"]}"#.utf8)
            .write(to: dir.appendingPathComponent("OverlayPresets.json"))

        #expect(store(dir).userPresets() == [OverlayLayout(name: "Wet")])
    }

    // MARK: - Save as preset

    /// *Save as preset…* stores the layout under the given name, and saving the
    /// same name again (in any case) replaces it, in place, as typed.
    @Test func test_save_as_preset_adds_then_replaces_by_name() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = store(dir)
        var edited = layout("whatever")
        edited.isEnabled = false

        try presets.savePreset(layout("A"), named: "Rain")
        try presets.savePreset(layout("B"), named: "Dry")
        let saved = try presets.savePreset(edited, named: "  rain ")

        #expect(saved.map(\.name) == ["rain", "Dry"])
        #expect(saved.first?.isEnabled == false)
        #expect(presets.userPresets() == saved)
    }

    /// A preset needs a name.
    @Test func test_a_blank_preset_name_is_refused() {
        #expect(throws: OverlayPresetStoreError.emptyName) {
            try store(makeTempDir()).savePreset(layout("A"), named: "   ")
        }
    }

    /// Deleting removes the named preset; an unknown name changes nothing.
    @Test func test_delete_preset_by_name() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presets = store(dir)
        try presets.save([layout("Rain"), layout("Dry")])

        #expect(try presets.deletePreset(named: "rain").map(\.name) == ["Dry"])
        #expect(try presets.deletePreset(named: "Snow").map(\.name) == ["Dry"])
        #expect(presets.userPresets().map(\.name) == ["Dry"])
    }

    // MARK: - Failures

    /// A failed write throws and leaves the previous library intact.
    @Test func test_a_failed_write_throws_and_keeps_the_old_file() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store(dir).save([layout("Wet")])
        struct DiskFull: Error {}

        #expect(throws: OverlayPresetStoreError.ioFailure) {
            try store(dir, write: { _, _ in throw DiskFull() }).save([layout("Dry")])
        }
        #expect(store(dir).userPresets() == [layout("Wet")])
    }

    /// Saving over a file that could not be read keeps it aside first, so a
    /// hand-edit gone wrong is never silently destroyed.
    @Test func test_saving_over_a_corrupt_file_keeps_it_aside() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))

        try store(dir).savePreset(layout("Wet"), named: "Wet")

        let kept = try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.corrupt.json"))
        #expect(String(bytes: kept, encoding: .utf8) == "{not json")
        #expect(store(dir).userPresets().map(\.name) == ["Wet"])
    }
}
