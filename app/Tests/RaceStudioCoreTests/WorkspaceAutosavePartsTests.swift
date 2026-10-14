import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for ``WorkspaceAutosave`` (issue 9.20): every part of the workspace is
/// saved when it changes, and a write that fails — or a saved workspace that
/// can't be read — never costs the operator their work.
@MainActor
@Suite struct WorkspaceAutosavePartsTests: WorkspaceAutosaveFixture {

    // MARK: - Every part is saved

    /// The written workspace after `edit` and a second.
    private func written(after edit: (Window) async -> Void) async throws -> ProjectDocument? {
        let dir = try makeTempDir()
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)
        await autosave.open(window.parts)
        await edit(window)
        scheduler.advance()
        return saved(in: dir)
    }

    @Test func test_the_lap_selection_is_saved() async throws {
        let document = try await written { $0.model.setSelection(channelNames: ["RPM"], lapIndices: [2], reference: 2) }

        #expect(document?.selectedLaps.first?.lapIndices == [2])
        #expect(document?.layout.panes.flatMap(\.channelNames) == ["RPM"])
    }

    @Test func test_the_pane_layout_is_saved() async throws {
        let document = try await written { $0.model.videoDataPanes.setVisible(false, for: .map) }

        #expect(document?.videoData.isVisible(.map) == false)
    }

    @Test func test_a_hud_edit_is_saved() async throws {
        let document = try await written { $0.overlay.setShowsHUD(true) }

        #expect(document?.overlay?.isEnabled == true)
    }

    @Test func test_the_log_sheet_is_saved() async throws {
        let document = try await written { $0.logSheet.sheet.notes = "New tyres" }

        #expect(document?.logSheet.notes == "New tyres")
    }

    @Test func test_a_math_channel_is_saved() async throws {
        let document = try await written { _ = await $0.math.add(name: "Half", unit: "", expression: "RPM / 2") }

        #expect(document?.mathChannels == [MathChannelDef(name: "Half", unit: "", expression: "RPM / 2")])
    }

    @Test func test_the_splits_are_saved() async throws {
        let document = try await written { $0.splits.setSplitCount(6) }

        #expect(document?.splits?.splits.count == 6)
    }

    @Test func test_the_video_and_its_sync_are_saved() async throws {
        let document = try await written { [video] in $0.video.attachment = video.withOffset(-9.25) }

        #expect(document?.video == video.withOffset(-9.25))
    }

    // MARK: - Failures

    /// A failed write is said and tried again on the next change; the window
    /// keeps its state meanwhile.
    @Test func test_a_failed_write_is_said_and_tried_again() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)
        disk.failing = true

        window.model.select(layout: .trackMap)
        scheduler.advance()

        #expect(autosave.saveFailed)
        #expect(window.model.activeLayout == .trackMap)
        disk.failing = false
        window.logSheet.sheet.notes = "Retry"
        scheduler.advance()
        #expect(!autosave.saveFailed)
        #expect(saved(in: dir)?.activeLayout == .trackMap)
        #expect(saved(in: dir)?.logSheet.notes == "Retry")
    }

    /// A failed write is also tried again when the session closes.
    @Test func test_a_failed_write_is_tried_again_on_close() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)
        disk.failing = true
        window.model.select(layout: .trackMap)
        scheduler.advance()

        disk.failing = false
        autosave.flush()

        #expect(!autosave.saveFailed)
        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    /// An unreadable saved workspace is kept aside: the session opens with the
    /// defaults, says so, and saves its new workspace from the next change.
    @Test func test_an_unreadable_workspace_opens_with_the_defaults_and_says_so() async throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        try Data("garbage".utf8).write(to: store.url(forSession: contentID))
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store, scheduler: scheduler)

        await autosave.open(window.parts)
        window.model.select(layout: .trackMap)
        scheduler.advance()

        #expect(autosave.notice?.details(locale: Locale(identifier: "en"))
            == [ProjectLoadWarning.unreadableWorkspace(keptAside: true).label(locale: Locale(identifier: "en"))])
        #expect(!autosave.saveFailed)
        #expect(try Data(contentsOf: store.asideURL(forSession: contentID)) == Data("garbage".utf8))
        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    /// An unreadable workspace that couldn't be kept aside is never written
    /// over: the session says its changes aren't being saved.
    @Test func test_an_unreadable_workspace_that_stays_in_place_is_never_overwritten() async throws {
        let dir = try makeTempDir()
        let disk = Disk()
        let store = store(in: dir, disk: disk)
        try Data("garbage".utf8).write(to: store.url(forSession: contentID))
        // A read-only folder: the file reads, but nothing in it can move.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store, scheduler: scheduler)

        await autosave.open(window.parts)
        window.model.select(layout: .trackMap)
        scheduler.advance()
        autosave.flush()

        #expect(autosave.notice?.details(locale: Locale(identifier: "en"))
            == [ProjectLoadWarning.unreadableWorkspace(keptAside: false).label(locale: Locale(identifier: "en"))])
        #expect(disk.writes == 0)
        #expect(try Data(contentsOf: store.url(forSession: contentID)) == Data("garbage".utf8))
    }

    /// The two unreadable-workspace warnings read in plain words, in English
    /// and Portuguese, and log in English.
    @Test func test_the_unreadable_workspace_warnings_read_in_both_languages() {
        let english = Locale(identifier: "en"), portuguese = Locale(identifier: "pt-BR")

        let warnings = [ProjectLoadWarning.unreadableWorkspace(keptAside: true), .unreadableWorkspace(keptAside: false)]
        for warning in warnings {
            #expect(!warning.label(locale: english).isEmpty)
            #expect(warning.label(locale: portuguese) != warning.label(locale: english))
            #expect(warning.text.contains("workspace"))
        }
    }
}
