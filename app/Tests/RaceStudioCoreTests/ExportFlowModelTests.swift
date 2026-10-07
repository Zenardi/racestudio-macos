import Foundation
import Testing
@testable import RaceStudioCore

/// A window's part in the app's one overlay export (issue 9.14): which sheet
/// is up, whether this window's export is being prepared or running, and what
/// the window does when that export ends — so the shell only applies it.
@MainActor
@Suite struct ExportFlowModelTests: ExportFlowTesting {

    /// A fresh flow owns nothing, names no file, and has nothing to cancel.
    @Test func test_a_fresh_flow_is_quiet() {
        let flow = ExportFlowModel()

        flow.cancelPreparation()

        #expect(flow.fileName == "")
        #expect(flow.route == nil)
        #expect(!flow.isBusy)
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

        #expect(flow.beginExport(to: destination, progress: ExportProgressModel()) != nil)
        #expect(flow.route == nil, "the settings sheet goes first")
        flow.sheetDismissed()

        #expect(flow.route == .progress)
        #expect(flow.isPreparing)
        #expect(flow.fileName == "lap.mp4")
    }

    /// With no sheet up, the progress sheet comes up at once.
    @Test func test_an_export_with_no_sheet_up_shows_progress_at_once() {
        let flow = ExportFlowModel()

        #expect(flow.beginExport(to: destination, progress: ExportProgressModel()) != nil)

        #expect(flow.route == .progress)
    }

    /// While the app's export runs, or this window prepares one, no other
    /// export starts.
    @Test func test_an_export_is_refused_while_another_runs_or_is_prepared() {
        let (progress, _) = running(to: URL(fileURLWithPath: "/tmp/other.mp4"))
        let flow = ExportFlowModel()
        let preparing = ExportFlowModel()
        _ = preparing.beginExport(to: destination, progress: ExportProgressModel())

        #expect(flow.beginExport(to: destination, progress: progress) == nil)
        #expect(preparing.beginExport(to: destination, progress: ExportProgressModel()) == nil)
        #expect(flow.route == nil)
    }

    /// The preparation ends, and the export may start…
    @Test func test_a_prepared_export_may_start() throws {
        let flow = ExportFlowModel()
        let preparation = try #require(flow.beginExport(to: destination, progress: ExportProgressModel()))

        #expect(flow.endPreparation(preparation))
        #expect(!flow.isPreparing)
    }

    /// …unless it was cancelled meanwhile: then nothing starts and the sheet
    /// goes.
    @Test func test_a_cancelled_preparation_starts_nothing() throws {
        let flow = ExportFlowModel()
        let preparation = try #require(flow.beginExport(to: destination, progress: ExportProgressModel()))

        flow.cancelPreparation()

        #expect(!flow.isPreparing)
        #expect(flow.route == nil)
        #expect(!flow.endPreparation(preparation))
        #expect(!flow.owns(ExportProgressModel()))
    }

    /// A preparation cancelled and then replaced by a new export can neither
    /// start nor fail the new one, however late it returns.
    @Test func test_a_stale_preparation_cannot_start_or_fail_the_next_export() throws {
        let flow = ExportFlowModel()
        let stale = try #require(flow.beginExport(to: URL(fileURLWithPath: "/tmp/old.mp4"),
                                                  progress: ExportProgressModel()))
        flow.cancelPreparation()
        let current = try #require(flow.beginExport(to: destination, progress: ExportProgressModel()))

        flow.failPreparation(stale, message)
        #expect(!flow.endPreparation(stale))

        #expect(flow.failure == nil)
        #expect(flow.isPreparing)
        #expect(flow.fileName == "lap.mp4")
        #expect(flow.endPreparation(current))
    }

    /// The current preparation's failure is shown.
    @Test func test_the_current_preparation_can_fail() throws {
        let flow = ExportFlowModel()
        let preparation = try #require(flow.beginExport(to: destination, progress: ExportProgressModel()))

        flow.failPreparation(preparation, message)

        #expect(flow.failure == message)
        #expect(!flow.isPreparing)
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

    /// A failure while the progress sheet is up shows in that sheet — it is
    /// not taken down and put up again.
    @Test func test_a_failure_shows_in_the_progress_sheet_already_up() {
        let flow = ExportFlowModel()
        _ = flow.beginExport(to: destination, progress: ExportProgressModel())

        flow.failed(message)

        #expect(flow.route == .progress, "still up")
        flow.sheetDismissed()
        #expect(flow.route == .progress, "nothing waiting to come up")
    }

}
