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
        let spy = LogSpy()

        #expect(store(dir, spy: spy).userPresets() == [OverlayLayout(name: "Wet")])
        #expect(spy.errors == [.skippedEntries(2)])
    }

    /// A widget this build can't read inside a preset is skipped too, and the
    /// next save keeps the original aside rather than silently losing it.
    @Test func test_a_lossy_library_is_kept_aside_before_it_is_rewritten() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = #"{"presets": [{"name": "Wet", "widgets": [{"kind": {"type": "laser"}, "#
            + #""frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}}]}]}"#
        try Data(original.utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        try store(dir, spy: spy).savePreset(layout("Dry"), named: "Dry")

        let kept = try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup.json"))
        #expect(String(bytes: kept, encoding: .utf8) == original)
        #expect(spy.errors == [.skippedEntries(1)])
        #expect(store(dir).userPresets().map(\.name) == ["Wet", "Dry"])
    }

    /// A widget that can't be read counts once, however many of its settings
    /// are broken too.
    @Test func test_an_unreadable_widget_counts_once() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = #"{"presets": [{"name": "A", "widgets": [{"id": 5, "anchor": "sideways", "#
            + #""kind": {"type": "laser"}, "frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}}]}]}"#
        try Data(original.utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        #expect(store(dir, spy: spy).userPresets().map(\.widgets.count) == [0])
        #expect(spy.errors == [.skippedEntries(1)])
    }

    /// Saves that keep failing over the same unread library keep one backup of
    /// it, not one per attempt.
    @Test func test_retried_saves_keep_one_backup_of_the_same_file() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        struct DiskFull: Error {}
        let failing = store(dir, write: { _, _ in throw DiskFull() })

        for _ in 0..<3 { _ = try? failing.savePreset(layout("Wet"), named: "Wet") }

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["OverlayPresets.backup.json", "OverlayPresets.json"])
    }

    /// A library written by a newer build is read as far as this build can, said
    /// so, kept aside, and rewritten in this build's format.
    @Test func test_a_newer_library_format_is_read_kept_aside_and_rewritten() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("OverlayPresets.json")
        let newer = #"{"schema": 9, "presets": [{"name": "Wet"}]}"#
        try Data(newer.utf8).write(to: url)
        let spy = LogSpy()

        try store(dir, spy: spy).savePreset(layout("Dry"), named: "Dry")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["schema"] as? Int == 1)
        #expect(spy.errors == [.newerFormat(9)])
        #expect(try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup.json")) == Data(newer.utf8))
        #expect(store(dir).userPresets().map(\.name) == ["Wet", "Dry"])
    }

    /// A preset list that isn't a list is an unreadable library — kept aside on
    /// the next save — not an empty one.
    @Test func test_a_preset_list_of_the_wrong_type_is_unreadable() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = #"{"presets": {"name": "Wet"}}"#
        try Data(original.utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        try store(dir, spy: spy).savePreset(layout("Dry"), named: "Dry")

        #expect(spy.errors == [.corruptFile])
        #expect(try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup.json")) == Data(original.utf8))
    }

    /// A setting this build can't read — an anchor, a widget list, a theme — reads
    /// as its default, and counts as not read in full: logged, and kept aside.
    @Test func test_unreadable_settings_count_as_skipped() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = #"{"presets": [{"name": "A", "theme": "neon", "widgets": [{"kind": {"type": "speed"}, "#
            + #""frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}, "anchor": "sideways"}]}, "#
            + #"{"name": "B", "widgets": "oops"}]}"#
        try Data(original.utf8).write(to: dir.appendingPathComponent("OverlayPresets.json"))
        let spy = LogSpy()

        try store(dir, spy: spy).deletePreset(named: "Nothing")

        #expect(spy.errors == [.skippedEntries(3)])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("OverlayPresets.backup.json").path))
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

    /// A built-in's name, in any shipped language, is taken: the menu could not
    /// tell the two apart.
    @Test(arguments: ["minimal", "Kart Coaching", "Telemetria completa"])
    func test_a_built_in_name_is_refused(name: String) {
        #expect(throws: OverlayPresetStoreError.reservedName) {
            try store(makeTempDir()).savePreset(layout("A"), named: name)
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

        let kept = try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup.json"))
        #expect(String(bytes: kept, encoding: .utf8) == "{not json")
        #expect(store(dir).userPresets().map(\.name) == ["Wet"])
    }

    /// A second unreadable library never overwrites the first one's backup.
    @Test func test_each_backup_is_kept() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("OverlayPresets.json")
        try Data("first".utf8).write(to: url)
        try store(dir).deletePreset(named: "Wet")
        try Data("second".utf8).write(to: url)

        try store(dir).deletePreset(named: "Wet")

        #expect(try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup.json")) == Data("first".utf8))
        #expect(try Data(contentsOf: dir.appendingPathComponent("OverlayPresets.backup-2.json"))
            == Data("second".utf8))
    }

    /// When the backup itself can't be made, nothing is overwritten.
    @Test func test_a_failed_backup_keeps_the_original_and_throws() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("OverlayPresets.json")
        try Data("{not json".utf8).write(to: url)
        let presets = OverlayPresetStore(directory: dir, fileManager: CopyRefusingFileManager(), log: { _ in })

        #expect(throws: OverlayPresetStoreError.ioFailure) { try presets.savePreset(layout("Wet"), named: "Wet") }
        #expect(try Data(contentsOf: url) == Data("{not json".utf8))
    }

    /// A file manager that cannot copy — the backup step fails.
    private final class CopyRefusingFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    }
}
