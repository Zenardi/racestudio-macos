import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for ``WorkspaceAutosave`` (issue 9.20) at its edges — the review of
/// the first cut: nothing the operator does while a workspace restores is
/// lost, a math channel that can't be re-created isn't deleted, a cancelled
/// open still restores everything, a drag still open is saved on close, two
/// windows on one session never write over each other, and changes that
/// aren't part of the workspace never arm a write.
@MainActor
@Suite struct WorkspaceAutosaveSafetyTests: WorkspaceAutosaveFixture {

    private let english = Locale(identifier: "en")

    // MARK: - While it restores

    /// A change made while the footage is still restoring is saved.
    @Test func test_a_change_made_while_the_workspace_restores_is_saved() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let scheduler = ManualScheduler(), window = window()
        let model = window.model
        window.video.onRestore = { model.select(layout: .trackMap) }
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)

        await autosave.open(window.parts)
        scheduler.advance()

        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    /// A cancelled open — the window's task torn down mid-restore — still
    /// restores everything before it saves anything.
    @Test func test_a_cancelled_open_still_restores_everything() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let window = window(evaluator: CancellableEvaluator())
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: ManualScheduler())

        let opening = Task { await autosave.open(window.parts) }
        opening.cancel()
        await opening.value

        #expect(window.math.definitions == document.mathChannels)
        #expect(window.video.restored.count == 1)
    }

    /// A second open waits for the first and restores nothing twice.
    @Test func test_opening_twice_restores_once() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: ManualScheduler())

        let first = Task { await autosave.open(window.parts) }
        await autosave.open(window.parts)
        await first.value

        #expect(window.math.definitions == document.mathChannels)
        #expect(window.video.restored.count == 1)
    }

    // MARK: - Math channels

    /// A math channel the session can't evaluate now is kept with the
    /// workspace — a change elsewhere never deletes it — and the open says so.
    @Test func test_a_math_channel_that_cannot_be_recreated_is_kept() async throws {
        let dir = try makeTempDir()
        let document = try await savedWorkspace(in: dir)
        let scheduler = ManualScheduler(), window = window(evaluator: TwoSampleEvaluator(failing: ["RPM * 2"]))
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)

        await autosave.open(window.parts)
        window.model.select(layout: .trackMap)
        scheduler.advance()

        #expect(window.math.definitions.isEmpty)
        #expect(autosave.notice?.details(locale: english)
            == [ProjectLoadWarning.unrestoredMathChannel("Double RPM").label(locale: english)])
        #expect(saved(in: dir)?.mathChannels == document.mathChannels)
        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    /// A channel added under a kept channel's name replaces it.
    @Test func test_a_new_channel_replaces_a_kept_one_of_the_same_name() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let scheduler = ManualScheduler(), window = window(evaluator: TwoSampleEvaluator(failing: ["RPM * 2"]))
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)
        await autosave.open(window.parts)

        _ = await window.math.add(name: "Double RPM", unit: "rpm", expression: "RPM + RPM")
        scheduler.advance()

        #expect(saved(in: dir)?.mathChannels == [MathChannelDef(name: "Double RPM", unit: "rpm",
                                                                expression: "RPM + RPM")])
    }

    /// Restoring the math channels leaves a draft being typed alone.
    @Test func test_restoring_math_channels_keeps_the_draft() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let window = window()
        window.math.editor.update(text: "GPS Speed / 2")
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: ManualScheduler())

        await autosave.open(window.parts)

        #expect(window.math.editor.text == "GPS Speed / 2")
        #expect(window.math.rejection == nil)
    }

    // MARK: - Closing

    /// Closing mid-drag saves the drag.
    @Test func test_closing_saves_a_drag_still_in_progress() async throws {
        let dir = try makeTempDir()
        let window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: ManualScheduler())
        await autosave.open(window.parts)
        window.overlay.select("speed")

        window.overlay.beginGesture()
        window.overlay.drag(by: CGSize(width: 0.05, height: 0))
        autosave.flush()

        #expect(saved(in: dir)?.overlay == window.overlay.layout)
        #expect(window.overlay.canUndo)
    }

    // MARK: - Two windows on one session

    /// A second window on a session restores its workspace but never writes
    /// over the first window's, and says so.
    @Test func test_a_second_window_on_the_session_never_writes() async throws {
        let dir = try makeTempDir()
        let disk = Disk(), firstClock = ManualScheduler(), secondClock = ManualScheduler()
        let first = window(), second = window()
        let firstSave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: firstClock)
        let secondSave = WorkspaceAutosave(store: store(in: dir, disk: disk), scheduler: secondClock)
        await firstSave.open(first.parts)
        await secondSave.open(second.parts)

        second.model.select(layout: .trackMap)
        secondClock.advance()
        secondSave.flush()

        #expect(disk.writes == 0)
        #expect(secondSave.notice?.details(locale: english)
            == [ProjectLoadWarning.openInAnotherWindow.label(locale: english)])
        first.model.select(layout: .lapOverlay)
        firstClock.advance()
        #expect(saved(in: dir)?.activeLayout == .lapOverlay)
    }

    /// Once the first window is gone, the next one opened saves.
    @Test func test_a_closed_window_frees_the_session() async throws {
        let dir = try makeTempDir()
        do {
            let first = WorkspaceAutosave(store: store(in: dir), scheduler: ManualScheduler())
            await first.open(window().parts)
        }
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)

        await autosave.open(window.parts)
        window.model.select(layout: .trackMap)
        scheduler.advance()

        #expect(autosave.notice == nil)
        #expect(saved(in: dir)?.activeLayout == .trackMap)
    }

    // MARK: - Changes that aren't the workspace

    /// Searching or sorting the channel list, or focusing a split, isn't part
    /// of the workspace, so it arms no write.
    @Test func test_changes_outside_the_workspace_arm_no_write() async throws {
        let dir = try makeTempDir()
        let scheduler = ManualScheduler(), window = window()
        let autosave = WorkspaceAutosave(store: store(in: dir), scheduler: scheduler)
        await autosave.open(window.parts)

        window.model.setChannelQuery("RPM")
        window.model.setChannelSort(.alphabetical)
        window.splits.focus(window.splits.layout.splits[0].id)

        #expect(scheduler.delays.isEmpty)
    }

    /// The warnings read in both languages and log in English.
    @Test func test_the_new_warnings_read_in_both_languages() {
        let portuguese = Locale(identifier: "pt-BR")

        for warning in [ProjectLoadWarning.openInAnotherWindow, .unrestoredMathChannel("Double RPM")] {
            #expect(warning.label(locale: portuguese) != warning.label(locale: english))
            #expect(!warning.text.isEmpty)
        }
        #expect(ProjectLoadWarning.unrestoredMathChannel("Double RPM").label(locale: english).contains("Double RPM"))
    }
}
