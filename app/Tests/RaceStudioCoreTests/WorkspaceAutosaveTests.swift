import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for ``WorkspaceAutosave`` (issue 9.20): a session's workspace is
/// restored when the session opens and written on its own a second after each
/// change — once per burst, never when nothing changed, at once when the
/// session closes — with no Save command.
@MainActor
@Suite struct WorkspaceAutosaveTests: WorkspaceAutosaveFixture {

    // MARK: - Opening

    /// Opening a session brings its workspace back as it was left — and
    /// writes nothing, since nothing changed.
    @Test func test_opening_restores_the_saved_workspace() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)

        await autosave.open(window.parts)
        scheduler.advance()

        #expect(window.model.selection.channels == [ChannelID("RPM")])
        #expect(window.model.selection.laps.selected == [LapID(1), LapID(2)])
        #expect(window.model.selection.laps.reference == LapID(2))
        #expect(window.model.activeLayout == .videoReview)
        #expect(!window.model.videoDataPanes.isVisible(.lapList))
        #expect(window.model.videoOverlay == document.overlay)
        #expect(window.overlay.layout == document.overlay)
        #expect(window.logSheet.sheet.notes == "Wet track")
        #expect(window.math.definitions == document.mathChannels)
        #expect(window.splits.layout == document.splits)
        #expect(window.video.restored.map(\.attachment) == [video])
        #expect(window.video.restored.map(\.epoch) == [1_700_000_000])
        #expect(autosave.notice == nil)
        #expect(disk.writes == 0)
    }

    /// A session never saved opens with the defaults and writes nothing until
    /// something changes.
    @Test func test_a_session_without_a_saved_workspace_opens_with_the_defaults() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)

        await autosave.open(window.parts)
        scheduler.advance()

        #expect(window.model.activeLayout == window.model.layouts.first)
        #expect(window.video.restored.isEmpty)
        #expect(autosave.notice == nil)
        #expect(disk.writes == 0)
        #expect(saved(in: dir) == nil)
    }

    /// What a load could not read in full is said, as it was for an opened
    /// workspace file.
    @Test func test_what_the_load_could_not_read_is_said() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let window = window()
        let validator = FakeExpressionValidator(invalid: ["RPM * 2"])
        let autosave = WorkspaceAutosave(store: store(in: dir, validator: validator), scheduler: ManualScheduler())

        await autosave.open(window.parts)

        #expect(autosave.notice?.details(locale: Locale(identifier: "en")).count == 1)
        autosave.dismissNotice()
        #expect(autosave.notice == nil)
    }

    // MARK: - Saving

    /// A change is written a second later, under the session's content id.
    @Test func test_a_change_is_written_a_second_later() async throws {
        let dir = try makeTempDir()
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)
        await autosave.open(window.parts)

        window.model.select(layout: .trackMap)

        #expect(scheduler.delays == [.seconds(1)])
        #expect(saved(in: dir) == nil)
        scheduler.advance()
        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    /// A burst of changes is written once, with the last state.
    @Test func test_a_burst_of_changes_is_written_once() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)

        window.model.select(layout: .trackMap)
        window.logSheet.sheet.notes = "Dry"
        window.model.select(layout: .lapOverlay)
        scheduler.advance()

        #expect(scheduler.delays.count == 1)
        #expect(disk.writes == 1)
        #expect(saved(in: dir)?.activeLayout == .lapOverlay)
        #expect(saved(in: dir)?.logSheet.notes == "Dry")
    }

    /// A change undone before the write writes nothing.
    @Test func test_an_unchanged_workspace_writes_nothing() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)
        let first = window.model.activeLayout

        window.model.select(layout: .trackMap)
        window.model.select(layout: first)
        scheduler.advance()

        #expect(disk.writes == 0)
    }

    /// A change after a write is written again.
    @Test func test_each_settled_change_is_written() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)

        window.model.select(layout: .trackMap)
        scheduler.advance()
        window.model.select(layout: .lapOverlay)
        scheduler.advance()

        #expect(disk.writes == 2)
        #expect(saved(in: dir)?.activeLayout == .lapOverlay)
    }

    // MARK: - Closing

    /// Closing the session writes a pending change at once, and the timer
    /// that was waiting writes nothing more.
    @Test func test_a_pending_change_is_written_when_the_session_closes() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)
        await autosave.open(window.parts)

        window.model.select(layout: .trackMap)
        autosave.flush()

        #expect(disk.writes == 1)
        #expect(saved(in: dir)?.activeLayout == .trackMap)
        scheduler.advance()
        #expect(disk.writes == 1)
    }

    /// Closing with nothing changed writes nothing.
    @Test func test_closing_with_nothing_changed_writes_nothing() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: ManualScheduler())
        await autosave.open(window.parts)

        autosave.flush()

        #expect(disk.writes == 0)
    }

    /// A window closed before its workspace finished opening never writes its
    /// defaults over the saved one.
    @Test func test_closing_before_the_workspace_opened_never_overwrites_it() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let disk = Disk(), scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: scheduler)

        window.model.select(layout: .trackMap)
        autosave.noteChange()
        scheduler.advance()
        autosave.flush()

        #expect(disk.writes == 0)
        #expect(saved(in: dir) == document)
    }
}
