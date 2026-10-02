#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
import Combine
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Download-queue tests for the device panel (issue #179): sessions download
/// one after another into the library, failures are reported while the queue
/// moves on, cancel stops it with nothing partial imported, and a report can be
/// retried.
@MainActor
@Suite struct DevicePanelDownloadTests {

    @Test func test_download_imports_each_selected_session_in_order() async throws {
        let harness = try await DevicePanelFixtures.atSessions()
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.importer.imported.map(\.session) == chosen)
        #expect(harness.importer.imported.map(\.data) == chosen.map { Data($0.fileName.utf8) })
    }

    @Test func test_finished_report_lists_the_imported_sessions() async throws {
        let harness = try await DevicePanelFixtures.atSessions()
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.model.state == .finished(harness.device, harness.sessions,
            DownloadReport(imported: chosen, failed: [], notDownloaded: [])))
    }

    @Test func test_download_reports_position_and_clamped_progress() async throws {
        let harness = try await DevicePanelFixtures.atSessions(progress: [0.5, 1.5])
        let chosen = Array(harness.sessions.prefix(2))
        var seen: [DownloadProgressState] = []
        let watch = harness.model.$state.sink { state in
            if case let .downloading(_, _, progress) = state { seen.append(progress) }
        }

        await harness.model.download(chosen)
        watch.cancel()

        #expect(seen.map(\.position) == [1, 1, 1, 2, 2, 2])
        #expect(seen.map(\.fraction) == [0, 0.5, 1, 0, 0.5, 1])
        #expect(seen.allSatisfy { $0.count == 2 })
    }

    @Test func test_failed_download_is_reported_and_the_queue_continues() async throws {
        let harness = try await DevicePanelFixtures.atSessions(
            failures: ["a_0062.xrz": DiscoveryError.MissingChunk(message: "a chunk is missing")])
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.model.state == .finished(harness.device, harness.sessions, DownloadReport(
            imported: [chosen[1]],
            failed: [DownloadFailure(session: chosen[0], message: "a chunk is missing")],
            notDownloaded: [])))
    }

    @Test func test_failed_import_is_reported() async throws {
        let harness = try await DevicePanelFixtures.atSessions(failingImports: ["a_0061.xrz"])
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.model.state == .finished(harness.device, harness.sessions, DownloadReport(
            imported: [chosen[0]],
            failed: [DownloadFailure(session: chosen[1], message: "the session could not be decoded")],
            notDownloaded: [])))
    }

    @Test func test_cancel_stops_the_queue_and_imports_nothing_partial() async throws {
        let harness = try await DevicePanelFixtures.atSessions(holdsDownloads: true)
        let chosen = Array(harness.sessions.prefix(3))
        let queue = Task { await harness.model.download(chosen) }
        await DevicePanelFixtures.untilDownloading(harness.model)

        await harness.model.cancelDownload()
        await queue.value

        #expect(harness.importer.imported.isEmpty)
        #expect(harness.service.downloadCalls == ["a_0062.xrz"])
        #expect(harness.model.state == .finished(harness.device, harness.sessions,
            DownloadReport(imported: [], failed: [], notDownloaded: chosen)))
    }

    @Test func test_device_cancellation_stops_the_queue() async throws {
        let harness = try await DevicePanelFixtures.atSessions(
            failures: ["a_0062.xrz": DiscoveryError.Cancelled(message: "cancelled")])
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.model.state == .finished(harness.device, harness.sessions,
            DownloadReport(imported: [], failed: [], notDownloaded: chosen)))
    }

    @Test func test_task_cancellation_stops_the_queue() async throws {
        let harness = try await DevicePanelFixtures.atSessions(failures: ["a_0062.xrz": CancellationError()])
        let chosen = Array(harness.sessions.prefix(2))

        await harness.model.download(chosen)

        #expect(harness.service.downloadCalls == ["a_0062.xrz"])
    }

    @Test func test_retry_queues_the_failed_and_skipped_sessions() async throws {
        let harness = try await DevicePanelFixtures.atSessions(
            failures: ["a_0062.xrz": DiscoveryError.MissingChunk(message: "gap")])
        await harness.model.download(Array(harness.sessions.prefix(2)))

        await harness.model.retry()

        #expect(harness.service.downloadCalls == ["a_0062.xrz", "a_0061.xrz", "a_0062.xrz"])
    }

    @Test func test_retry_is_ignored_without_a_report() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        await harness.model.retry()

        #expect(harness.service.downloadCalls.isEmpty)
    }

    @Test func test_empty_selection_downloads_nothing() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        await harness.model.download([])

        #expect(harness.model.state == .sessions(harness.device, harness.sessions))
    }

    @Test func test_download_is_ignored_without_a_table() async throws {
        let service = FakeDeviceService()
        let model = DevicePanelModel(service: service, importer: FakeSessionImporter())

        await model.download(try DevicePanelFixtures.goldenSessions())

        #expect(service.downloadCalls.isEmpty)
    }

    @Test func test_cancel_is_ignored_when_nothing_downloads() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        await harness.model.cancelDownload()

        #expect(harness.service.cancelCount == 0)
    }

    @Test func test_back_to_sessions_leaves_the_report() async throws {
        let harness = try await DevicePanelFixtures.atSessions()
        await harness.model.download([harness.sessions[0]])

        harness.model.showSessions()

        #expect(harness.model.state == .sessions(harness.device, harness.sessions))
    }

    @Test func test_download_can_start_again_from_a_report() async throws {
        let harness = try await DevicePanelFixtures.atSessions()
        await harness.model.download([harness.sessions[0]])

        await harness.model.download([harness.sessions[1]])

        #expect(harness.service.downloadCalls == ["a_0062.xrz", "a_0061.xrz"])
    }

    @Test func test_refresh_from_a_report_shows_the_table() async throws {
        let harness = try await DevicePanelFixtures.atSessions()
        await harness.model.download([harness.sessions[0]])

        await harness.model.refresh()

        #expect(harness.model.state == .sessions(harness.device, harness.sessions))
    }

    @Test func test_report_retryable_is_failed_then_skipped() throws {
        let sessions = try DevicePanelFixtures.goldenSessions()
        let report = DownloadReport(
            imported: [], failed: [DownloadFailure(session: sessions[0], message: "x")],
            notDownloaded: [sessions[1]])

        #expect(report.retryable == [sessions[0], sessions[1]])
    }
}
#endif
