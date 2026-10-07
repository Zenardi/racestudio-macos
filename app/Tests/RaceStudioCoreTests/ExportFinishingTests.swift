import AVFoundation
import Foundation
import Testing
@testable import RaceStudioCore

/// The end of an overlay export (issue 9.13): finishing the file — the
/// writer's fast-start pass — counts as the last step of the progress, so
/// 1.0 means done, and a cancel during it stops the writer and leaves no file.
@Suite(.enabled(if: VideoTests.isEnabled, VideoTests.skipReason)) struct ExportFinishingTests {

    // MARK: - Progress

    /// Every frame encoded is not yet done: the file still has to be finished.
    @Test func test_finishing_counts_as_the_last_step() {
        let encoding = ExportProgress(framesDone: 45, totalFrames: 90, elapsed: 1)
        let finishing = ExportProgress(framesDone: 90, totalFrames: 90, elapsed: 2, phase: .finishing)
        let complete = ExportProgress(framesDone: 90, totalFrames: 90, elapsed: 3, phase: .complete)

        #expect(encoding.phase == .encoding)
        #expect(encoding.fraction == 45.0 / 91)
        #expect(finishing.fraction == 90.0 / 91 && finishing.fraction < 1)
        #expect(finishing.estimatedRemaining.map { $0 > 0 } == true)
        #expect(complete.fraction == 1 && complete.estimatedRemaining == 0)
    }

    /// Only the export's last event, once its file is in place, is complete.
    @Test func test_only_the_last_event_is_complete() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let overlay = ExportOverlay(drawer: SlowSessionTimeBar(delay: 0.003),
                                    telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))

        let events = try await collect(sandbox.exporter(progressInterval: .milliseconds(20))
            .export(plan, overlay: overlay, to: sandbox.destination))

        #expect(events.dropLast().allSatisfy { $0.fraction < 1 && $0.phase != .complete })
        #expect(events.last?.phase == .complete)
    }

    // MARK: - Cancelling while finishing

    /// A pipeline over the synthetic footage writing to `file`, cancelled by
    /// `willFinish` as finishing begins.
    /// A pipeline over synthetic footage written by `spec`, writing to
    /// `file`, whose hooks are handed the pipeline: `willFinish` just before
    /// finishing begins, `didStartFinishing` on its queue once the writer has
    /// been told to finish.
    private func pipeline(in sandbox: ExportSandbox, file: URL, spec: TestMediaFactory.Spec = .init(),
                          willFinish: @escaping @Sendable (ExportPipeline) -> Void = { _ in },
                          didStartFinishing: @escaping @Sendable (ExportPipeline) -> Void = { _ in })
        async throws -> ExportPipeline {
        let plan = try await exportPlan(try await sandbox.footage(spec))
        let overlay = ExportOverlay(drawer: SessionTimeBar(origin: 0),
                                    telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))
        let composition = try await OverlayComposition.make(plan: plan, overlay: overlay)
        let box = PipelineBox()
        let pipeline = try await ExportPipeline(
            composition: composition, plan: plan, writingTo: file,
            willFinish: { if let pipeline = box.pipeline { willFinish(pipeline) } },
            didStartFinishing: { if let pipeline = box.pipeline { didStartFinishing(pipeline) } })
        box.pipeline = pipeline
        return pipeline
    }

    /// A cancel that arrives as the file is about to be finished cancels the
    /// writer instead of finishing it.
    @Test func test_a_cancel_as_finishing_begins_cancels_the_writer() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let file = sandbox.directory.appendingPathComponent("out.mp4")
        let pipeline = try await pipeline(in: sandbox, file: file, willFinish: { $0.cancel() })

        await #expect(throws: OverlayExportError.cancelled) { try await pipeline.run() }
        #expect(pipeline.writerStatus == .cancelled)
    }

    /// A cancel that lands once the writer has been told to finish — while its
    /// fast-start pass runs — cancels the writer itself; the run ends
    /// cancelled, never with a finished file.
    @Test func test_a_cancel_while_finishing_cancels_the_writer() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let file = sandbox.directory.appendingPathComponent("out.mp4")
        let busy = TestMediaFactory.Spec(width: 640, height: 360, noise: true, bitRate: 8_000_000)
        let pipeline = try await pipeline(in: sandbox, file: file, spec: busy, didStartFinishing: { $0.cancel() })

        await #expect(throws: OverlayExportError.cancelled) { try await pipeline.run() }
        #expect(pipeline.writerStatus == .cancelled, "the writer was cancelled mid-finish, not left to complete")
    }

    /// Cancelled while finishing, an export leaves an existing file at its
    /// destination exactly as it was, and no scratch file.
    @Test func test_a_cancel_while_finishing_keeps_an_existing_destination() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let older = Data("an older export".utf8)
        try older.write(to: sandbox.destination)
        let box = ExporterBox()
        let scratch = sandbox.scratch
        let exporter = OverlayVideoExporter(diskSpace: FakeDiskSpace(available: nil), progressInterval: .seconds(1),
                                            scratchDirectory: { _ in
                                                try FileManager.default.createDirectory(
                                                    at: scratch, withIntermediateDirectories: true)
                                                return scratch
                                            },
                                            willFinish: { await box.exporter?.cancel() })
        box.exporter = exporter
        let overlay = ExportOverlay(drawer: SessionTimeBar(origin: 0),
                                    telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))

        var error: Error?
        do {
            _ = try await collect(exporter.export(plan, overlay: overlay, to: sandbox.destination))
        } catch let thrown {
            error = thrown
        }

        #expect(error as? OverlayExportError == .cancelled)
        #expect(try Data(contentsOf: sandbox.destination) == older)
        #expect(!sandbox.scratchExists)
    }
}

/// Hands a pipeline to its own finishing hook.
private final class PipelineBox: @unchecked Sendable {
    var pipeline: ExportPipeline?
}

/// Hands an exporter to its own finishing hook.
private final class ExporterBox: @unchecked Sendable {
    var exporter: OverlayVideoExporter?
}
