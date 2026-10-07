import Foundation
import Testing
@testable import RaceStudioCore

/// A window's part in the app's one overlay export (issue 9.14): which sheet
/// is up, whether this window's export is being prepared or running, and what
/// the window does when that export ends — so the shell only applies it.
@MainActor
@Suite struct ExportFlowModelTests {

    private let destination = URL(fileURLWithPath: "/tmp/lap.mp4")
    private let message = ExportUserMessage(title: "The video can’t be read", fix: "Attach it again.")

    /// A sheet model to open.
    private func sheet() -> ExportSheetModel { ExportSheetFixture.model() }

    private typealias Feed = AsyncThrowingStream<ExportProgress, Error>.Continuation

    /// An app export, running to `url`.
    private func running(to url: URL) -> (ExportProgressModel, Feed) {
        let progress = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        progress.start(stream, to: url, cancel: {})
        return (progress, continuation)
    }

    // MARK: - Opening

    /// One open at a time: a second ⌥⌘E while the footage is probed, or
    /// while a sheet is up, is ignored.
    @Test func test_opening_is_not_re_entrant() {
        let flow = ExportFlowModel()

        #expect(flow.beginOpening())
        #expect(!flow.beginOpening(), "already opening")
        flow.opened(sheet())
        #expect(!flow.isOpening)
        #expect(!flow.beginOpening(), "a sheet is up")
    }

    /// The probed footage opens the settings sheet.
    @Test func test_an_opened_sheet_shows_the_settings() {
        let flow = ExportFlowModel()
        _ = flow.beginOpening()

        flow.opened(sheet())

        #expect(flow.route?.id == "settings")
        #expect(flow.failure == nil)
    }

    /// Footage that can't be probed shows why, in the progress sheet.
    @Test func test_a_failure_before_the_export_is_shown() {
        let flow = ExportFlowModel()
        _ = flow.beginOpening()

        flow.failed(message)

        #expect(flow.route == .progress)
        #expect(flow.failure == message)
        #expect(!flow.isOpening && !flow.isPreparing)
    }

    // MARK: - Starting

    /// Choosing where to save closes the settings sheet; the progress sheet
    /// comes up once it has gone, and the export is prepared.
    @Test func test_an_export_replaces_the_settings_sheet_once_it_has_gone() {
        let flow = ExportFlowModel()
        _ = flow.beginOpening()
        flow.opened(sheet())

        #expect(flow.beginExport(to: destination, progress: ExportProgressModel()))
        #expect(flow.route == nil, "the settings sheet goes first")
        flow.sheetDismissed()

        #expect(flow.route == .progress)
        #expect(flow.isPreparing)
        #expect(flow.fileName == "lap.mp4")
    }

    /// With no sheet up, the progress sheet comes up at once.
    @Test func test_an_export_with_no_sheet_up_shows_progress_at_once() {
        let flow = ExportFlowModel()

        #expect(flow.beginExport(to: destination, progress: ExportProgressModel()))

        #expect(flow.route == .progress)
    }

    /// While the app's export runs, or this window prepares one, no other
    /// export starts.
    @Test func test_an_export_is_refused_while_another_runs_or_is_prepared() {
        let (progress, _) = running(to: URL(fileURLWithPath: "/tmp/other.mp4"))
        let flow = ExportFlowModel()
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: destination, progress: ExportProgressModel())

        #expect(!flow.beginExport(to: destination, progress: progress))
        #expect(!preparing.beginExport(to: destination, progress: ExportProgressModel()))
        #expect(flow.route == nil)
    }

    /// The preparation ends, and the export may start…
    @Test func test_a_prepared_export_may_start() {
        let flow = ExportFlowModel()
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        #expect(flow.endPreparation())
        #expect(!flow.isPreparing)
    }

    /// …unless it was cancelled meanwhile: then nothing starts and the sheet
    /// goes.
    @Test func test_a_cancelled_preparation_starts_nothing() {
        let flow = ExportFlowModel()
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        flow.cancelPreparation()

        #expect(!flow.isPreparing)
        #expect(flow.route == nil)
        #expect(!flow.endPreparation())
        #expect(!flow.owns(ExportProgressModel()))
    }

    /// A failure while preparing — the overlay's telemetry would not load —
    /// leaves the window owning no export.
    @Test func test_a_failure_while_preparing_owns_nothing() {
        let (progress, _) = running(to: destination)
        let flow = ExportFlowModel()
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        flow.failed(message)

        #expect(!flow.owns(progress))
        #expect(!flow.isPreparing)
    }

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
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())
        _ = flow.endPreparation()
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
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())
        _ = flow.endPreparation()

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

    // MARK: - Guards

    /// Closing the window asks first while this window's export is prepared
    /// or runs; never for another window's, nor when none runs.
    @Test func test_closing_is_guarded_while_this_windows_export_runs() {
        let (progress, _) = running(to: destination)
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: URL(fileURLWithPath: "/tmp/next.mp4"), progress: ExportProgressModel())
        let starter = ExportFlowModel()
        _ = starter.beginExport(to: destination, progress: ExportProgressModel())
        _ = starter.endPreparation()

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
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())
        _ = flow.endPreparation()

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

extension ExportFlowModel.Route: Equatable {
    /// Test-only: routes compare by what they show.
    public static func == (lhs: ExportFlowModel.Route, rhs: ExportFlowModel.Route) -> Bool {
        lhs.id == rhs.id
    }
}
