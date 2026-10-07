import Foundation
import Testing
@testable import RaceStudioCore

/// How a window follows the app's one overlay export (issue 9.14): the
/// export it owns, what an end or a cancel does on screen, and when closing
/// the window asks first.
@MainActor
@Suite struct ExportFlowFollowingTests: ExportFlowTesting {

    // MARK: - Following the app's export

    /// The window owns the export it started — not another window's.
    @Test func test_a_window_owns_only_the_export_it_started() {
        let (progress, _) = running(to: destination)
        let starter = ExportFlowModel()
        _ = starter.beginExport(to: destination, progress: ExportProgressModel())
        let other = ExportFlowModel()

        #expect(starter.owns(progress))
        #expect(!other.owns(progress))
    }

    /// An export ending while its sheet is hidden brings the result back —
    /// in the window that started it only.
    @Test func test_an_ended_export_shows_its_result_in_its_window() {
        let (progress, _) = running(to: destination)
        let starter = ExportFlowModel()
        _ = starter.beginExport(to: destination, progress: ExportProgressModel())
        starter.dismiss()
        let other = ExportFlowModel()

        starter.exportChanged(to: .finished(destination), progress: progress)
        other.exportChanged(to: .finished(destination), progress: progress)

        #expect(starter.route == .progress)
        #expect(other.route == nil)
    }

    /// The badge brings a hidden sheet back; progress while it runs changes
    /// nothing on screen.
    @Test func test_the_badge_brings_the_sheet_back_and_progress_changes_nothing() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        started(flow)
        flow.dismiss()

        flow.exportChanged(to: .running, progress: progress)
        #expect(flow.route == nil)
        flow.showProgress()

        #expect(flow.route == .progress)
        #expect(flow.owns(progress))
    }

    /// A cancel that has cleaned up closes the progress sheet, and the window
    /// no longer owns an export.
    @Test func test_a_cleaned_up_cancel_closes_the_sheet() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        started(flow)

        flow.exportChanged(to: .idle, progress: progress)

        #expect(flow.route == nil)
        #expect(!flow.owns(progress))
    }

    /// A failure shown before the export started stays on screen.
    @Test func test_a_shown_failure_stays_when_the_export_is_idle() {
        let flow = ExportFlowModel()
        flow.failed(message)

        flow.exportChanged(to: .idle, progress: ExportProgressModel())

        #expect(flow.route == .progress)
    }

    /// *Done* puts the ended export away.
    @Test func test_done_puts_the_export_away() async {
        let (progress, continuation) = running(to: destination)
        let flow = ExportFlowModel()
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())
        continuation.finish()
        await progress.wait()

        flow.finish(progress: progress)

        #expect(progress.state == .idle)
        #expect(flow.route == nil)
        #expect(flow.failure == nil)
        #expect(!flow.owns(progress))
    }

    /// Dismissing forgets a sheet waiting to come up.
    @Test func test_dismiss_forgets_a_waiting_sheet() {
        let flow = ExportFlowModel()
        _ = flow.beginOpening()
        flow.opened(sheet())
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        flow.dismiss()
        flow.sheetDismissed()

        #expect(flow.route == nil)
    }

    /// The same state told twice — a re-subscription replaying it — does
    /// nothing twice: a result put away stays away.
    @Test func test_a_repeated_state_is_not_acted_on_twice() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        started(flow)
        flow.dismiss()

        flow.exportChanged(to: .finished(destination), progress: progress)
        flow.dismiss()
        flow.exportChanged(to: .finished(destination), progress: progress)

        #expect(flow.route == nil)
    }

    /// Another window's export starting closes a result this window still
    /// shows, rather than showing that export's progress in this sheet.
    @Test func test_another_windows_export_closes_a_shown_result() {
        let (progress, _) = running(to: URL(fileURLWithPath: "/tmp/other.mp4"))
        let flow = ExportFlowModel()
        flow.showProgress()

        flow.exportChanged(to: .running, progress: progress)

        #expect(flow.route == nil)
    }

    /// Once another window's export has started, this window's old export is
    /// no longer its own — even if a later export writes to the same file.
    @Test func test_another_windows_export_ends_this_windows_ownership() async {
        let (mine, feed) = running(to: destination)
        let flow = ExportFlowModel()
        started(flow)
        feed.finish()
        await mine.wait()
        flow.exportChanged(to: .finished(destination), progress: mine)
        let (other, _) = running(to: URL(fileURLWithPath: "/tmp/other.mp4"))
        flow.exportChanged(to: .running, progress: other)
        let (sameFile, _) = running(to: destination)

        #expect(!flow.owns(sameFile))
        #expect(!flow.guardsClose(progress: sameFile))
    }

    /// …but never this window's failure, nor its own preparation.
    @Test func test_another_windows_export_leaves_a_failure_or_a_preparation() {
        let (progress, _) = running(to: URL(fileURLWithPath: "/tmp/other.mp4"))
        let failed = ExportFlowModel()
        failed.failed(message)
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: destination, progress: ExportProgressModel())

        failed.exportChanged(to: .running, progress: progress)
        preparing.exportChanged(to: .running, progress: progress)

        #expect(failed.route == .progress)
        #expect(preparing.route == .progress)
    }

    /// A sheet asked for while another is still going away replaces the one
    /// waiting, instead of coming up over it.
    @Test func test_a_sheet_asked_for_while_one_goes_away_waits_its_turn() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        _ = flow.beginOpening()
        flow.opened(sheet())
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        flow.exportChanged(to: .finished(destination), progress: progress)
        #expect(flow.route == nil, "the settings sheet is still going")
        flow.sheetDismissed()
        #expect(flow.route == .progress)
        flow.dismiss()
        flow.sheetDismissed()

        #expect(flow.route == nil, "nothing left waiting")
    }

    // MARK: - Guards

    /// Closing the window asks first while this window's export is prepared
    /// or runs; never for another window's, nor when none runs.
    @Test func test_closing_is_guarded_while_this_windows_export_runs() {
        let (progress, _) = running(to: destination)
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: URL(fileURLWithPath: "/tmp/next.mp4"), progress: ExportProgressModel())
        let starter = ExportFlowModel()
        started(starter)

        #expect(preparing.guardsClose(progress: ExportProgressModel()))
        #expect(starter.guardsClose(progress: progress))
        #expect(!ExportFlowModel().guardsClose(progress: progress))
        #expect(!starter.guardsClose(progress: ExportProgressModel()))
    }

    /// The workspace bar's badge shows this window's running export while
    /// its sheet is hidden.
    @Test func test_the_badge_shows_a_hidden_running_export() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        started(flow)

        #expect(!flow.showsBadge(progress: progress), "the sheet is up")
        flow.dismiss()
        #expect(flow.showsBadge(progress: progress))
        #expect(!ExportFlowModel().showsBadge(progress: progress))
    }

    /// The command counts an export being opened or prepared as busy.
    @Test func test_opening_or_preparing_is_busy() {
        let opening = ExportFlowModel()
        _ = opening.beginOpening()
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: destination, progress: ExportProgressModel())

        #expect(opening.isBusy)
        #expect(preparing.isBusy)
        #expect(!ExportFlowModel().isBusy)
    }

    /// Routes are told apart by what they show.
    @Test func test_routes_are_identified_by_what_they_show() {
        #expect(ExportFlowModel.Route.settings(sheet()).id == "settings")
        #expect(ExportFlowModel.Route.progress.id == "progress")
    }
}
