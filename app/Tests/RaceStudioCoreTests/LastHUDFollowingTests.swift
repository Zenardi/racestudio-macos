import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for how a session follows the last HUD (issue 9.22, from the review
/// of its first cut): a session whose HUD was never edited keeps showing the
/// newest last HUD, an edit makes the HUD the session's own, and no edit is
/// lost — made while the workspace restores, or mid-drag in a second window.
@MainActor
@Suite struct LastHUDFollowingTests: WorkspaceAutosaveFixture {

    // MARK: - Fixture (no logic — fixed layouts)

    private let english = Locale(identifier: "en")

    /// A last HUD: a preset with the HUD on.
    private func hud(_ preset: OverlayPreset) -> OverlayLayout {
        var layout = preset.layout(locale: english)
        layout.isEnabled = true
        return layout
    }

    // MARK: - Following

    /// A session whose HUD was never edited is saved without one, so it
    /// shows the newest last HUD every time it opens.
    @Test func test_an_unedited_hud_follows_the_newest_last_hud() async throws {
        let dir = try makeTempDir()
        let last = LastOverlayStore(directory: dir)
        try last.save(hud(.fullTelemetry))
        let scheduler = ManualScheduler(), window = window()
        let saver = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: scheduler)
        await saver.open(window.parts)

        window.model.select(layout: .trackMap)
        scheduler.advance()
        try last.save(hud(.minimal))
        let reopened = self.window()
        let reopenedSave = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: ManualScheduler())
        await reopenedSave.open(reopened.parts)

        #expect(saved(in: dir)?.activeLayout == .trackMap)
        #expect(saved(in: dir)?.overlay == nil)
        #expect(reopened.model.videoOverlay == hud(.minimal))
    }

    /// Editing the HUD makes it the session's own: it is saved with the
    /// session, and a newer last HUD no longer replaces it.
    @Test func test_editing_the_hud_makes_it_the_sessions_own() async throws {
        let dir = try makeTempDir()
        let last = LastOverlayStore(directory: dir)
        try last.save(hud(.fullTelemetry))
        let scheduler = ManualScheduler(), window = window()
        let saver = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: scheduler)
        await saver.open(window.parts)

        window.overlay.setTextSize(1.5, for: "speed")
        scheduler.advance()
        try last.save(hud(.minimal))
        let reopened = self.window()
        let reopenedSave = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: ManualScheduler())
        await reopenedSave.open(reopened.parts)

        #expect(saved(in: dir)?.overlay == window.overlay.layout)
        #expect(reopened.model.videoOverlay == window.overlay.layout)
    }

    // MARK: - No edit lost

    /// A HUD edit made while the footage is still restoring is remembered as
    /// the last HUD.
    @Test func test_a_hud_edit_made_while_restoring_is_remembered() async throws {
        let dir = try makeTempDir()
        try await savedWorkspace(in: dir)
        let last = LastOverlayStore(directory: dir)
        let scheduler = ManualScheduler(), window = window()
        let editor = window.overlay
        window.video.onRestore = { editor.setTextSize(1.5, for: "speed") }
        let saver = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: scheduler)

        await saver.open(window.parts)
        scheduler.advance()

        #expect(last.load() == editor.layout)
        #expect(saved(in: dir)?.overlay == editor.layout)
    }

    /// Closing a second window on the session mid-drag — a window that doesn't
    /// save its workspace — still keeps the drag in the last HUD.
    @Test func test_closing_a_second_window_mid_drag_keeps_the_drag() async throws {
        let dir = try makeTempDir()
        let last = LastOverlayStore(directory: dir)
        let first = window(), second = window()
        let firstSave = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: ManualScheduler())
        let secondSave = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: ManualScheduler())
        await firstSave.open(first.parts)
        await secondSave.open(second.parts)
        second.overlay.select("speed")

        second.overlay.beginGesture()
        second.overlay.drag(by: CGSize(width: 0.05, height: 0))
        secondSave.flush()

        #expect(second.overlay.canUndo)
        #expect(last.load() == second.overlay.layout)
        #expect(firstSave.notice == nil)
    }
}
