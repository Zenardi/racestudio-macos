import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the last HUD (issue 9.22): every committed HUD edit is
/// remembered, and a session opened without a HUD of its own starts with it —
/// while a session with its own HUD keeps it, and nothing breaks without one.
@MainActor
@Suite struct LastHUDTests: WorkspaceAutosaveFixture {

    // MARK: - Fixture (no logic — fixed layouts and a counting store)

    private let english = Locale(identifier: "en")

    /// The operator's arrangement: Full telemetry, the HUD on, a bigger speed.
    private var arranged: OverlayLayout {
        var layout = OverlayPreset.fullTelemetry.layout(locale: english)
        layout.isEnabled = true
        layout.widgets[0].textSize = 1.5
        return layout
    }

    /// Every write the last-HUD store makes.
    private final class Writes {
        var count = 0
    }

    private func lastStore(in dir: URL, writes: Writes = Writes()) -> LastOverlayStore {
        LastOverlayStore(directory: dir, write: { data, url in
            writes.count += 1
            try data.write(to: url, options: .atomic)
        })
    }

    private func autosave(in dir: URL, last: LastOverlayStore, scheduler: ManualScheduler = ManualScheduler())
        -> WorkspaceAutosave {
        WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: scheduler)
    }

    // MARK: - The store

    /// The last HUD is kept in `LastOverlay.json` and read back.
    @Test func test_the_last_hud_is_saved_and_read_back() throws {
        let dir = try makeTempDir()
        let store = lastStore(in: dir)

        try store.save(arranged)

        #expect(store.url == dir.appendingPathComponent("LastOverlay.json"))
        #expect(store.load() == arranged)
    }

    /// No file, or one that isn't a layout, is no last HUD.
    @Test func test_no_or_an_unreadable_last_hud_is_none() throws {
        let dir = try makeTempDir()
        let store = lastStore(in: dir)
        #expect(store.load() == nil)

        try Data("not a layout".utf8).write(to: store.url)

        #expect(store.load() == nil)
    }

    /// The last HUD lives beside the library in Application Support.
    @Test func test_the_default_folder_is_beside_the_library() {
        #expect(LastOverlayStore.defaultDirectory() == LibraryStore.defaultURL().deletingLastPathComponent())
    }

    // MARK: - Remembering

    /// Each committed HUD edit is remembered as the last HUD.
    @Test func test_each_hud_edit_is_remembered() async throws {
        let dir = try makeTempDir()
        let last = lastStore(in: dir), window = window()
        let saver = autosave(in: dir, last: last)
        await saver.open(window.parts)

        window.overlay.apply(arranged)
        #expect(last.load() == window.overlay.layout)

        window.overlay.setTextSize(2, for: window.overlay.layout.widgets[1].id)
        #expect(last.load() == window.overlay.layout)
        #expect(!saver.saveFailed)
    }

    /// A last HUD that can't be written costs only itself: the edit stands
    /// and the workspace is still saved.
    @Test func test_a_last_hud_that_cannot_be_written_costs_nothing_else() async throws {
        let dir = try makeTempDir()
        let last = LastOverlayStore(directory: dir, write: { _, _ in throw WorkspaceDiskFull() })
        let scheduler = ManualScheduler(), window = window()
        let saver = autosave(in: dir, last: last, scheduler: scheduler)
        await saver.open(window.parts)

        window.overlay.setShowsHUD(true)
        scheduler.advance()

        #expect(window.model.videoOverlay?.isEnabled == true)
        #expect(last.load() == nil)
        #expect(saved(in: dir)?.overlay?.isEnabled == true)
        #expect(!saver.saveFailed)
    }

    /// Opening a session — with or without a HUD of its own — never changes
    /// the last HUD.
    @Test func test_opening_a_session_never_changes_the_last_hud() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let writes = Writes(), last = lastStore(in: dir, writes: writes)
        try last.save(arranged)
        let window = window()

        let saver = autosave(in: dir, last: last)
        await saver.open(window.parts)

        #expect(writes.count == 1)
        #expect(last.load() == arranged)
    }

    // MARK: - Starting a session

    /// A session with no workspace yet starts with the last HUD — in the
    /// window, so the export's *Current overlay* uses it, and in the editor,
    /// with nothing to undo — and writes nothing for it.
    @Test func test_a_new_session_starts_with_the_last_hud() async throws {
        let dir = try makeTempDir()
        let last = lastStore(in: dir)
        try last.save(arranged)
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), lastOverlay: last, scheduler: scheduler)

        await autosave.open(window.parts)
        scheduler.advance()

        #expect(window.model.videoOverlay == arranged)
        #expect(window.overlay.layout == arranged)
        #expect(!window.overlay.canUndo)
        #expect(disk.writes == 0)
    }

    /// A saved workspace without a HUD starts with the last one, and keeps it
    /// from then on.
    @Test func test_a_workspace_without_a_hud_starts_with_the_last_one() async throws {
        let dir = try makeTempDir()
        var document = try await savedWorkspace(in: dir)
        document.overlay = nil
        try store(in: dir).save(document, session: contentID)
        let last = lastStore(in: dir)
        try last.save(arranged)
        let scheduler = ManualScheduler(), window = window()

        let saver = autosave(in: dir, last: last, scheduler: scheduler)
        await saver.open(window.parts)
        scheduler.advance()

        #expect(window.model.videoOverlay == arranged)
        #expect(saved(in: dir)?.overlay == arranged)
        #expect(!saver.saveFailed)
    }

    /// A session with its own HUD opens with it, not the last one.
    @Test func test_a_session_with_its_own_hud_keeps_it() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let last = lastStore(in: dir)
        try last.save(arranged)
        let window = window()

        let saver = autosave(in: dir, last: last)
        await saver.open(window.parts)

        #expect(window.model.videoOverlay == document.overlay)
        #expect(window.overlay.layout == document.overlay)
    }

    /// Without a last HUD — none yet, or one that can't be read — a session
    /// starts as before: Kart coaching with the HUD off.
    @Test(arguments: [false, true])
    func test_without_a_last_hud_a_session_starts_as_before(corrupt: Bool) async throws {
        let dir = try makeTempDir()
        let last = lastStore(in: dir)
        if corrupt { try Data("{".utf8).write(to: last.url) }
        let window = window()

        let saver = autosave(in: dir, last: last)
        await saver.open(window.parts)

        #expect(window.model.videoOverlay == nil)
        #expect(window.overlay.layout == OverlayEditorModel(layout: nil).layout)
        #expect(!window.overlay.layout.isEnabled)
    }

    /// A second window on a session — which doesn't save its workspace —
    /// still starts with the last HUD, and still remembers its edits.
    @Test func test_a_second_window_still_starts_with_and_remembers_the_last_hud() async throws {
        let dir = try makeTempDir()
        let last = lastStore(in: dir)
        try last.save(arranged)
        let first = window(), second = window()
        let firstSave = autosave(in: dir, last: last), secondSave = autosave(in: dir, last: last)
        await firstSave.open(first.parts)
        await secondSave.open(second.parts)

        second.overlay.setShowsHUD(false)

        #expect(second.model.videoOverlay?.widgets == arranged.widgets)
        #expect(last.load()?.isEnabled == false)
    }
}
