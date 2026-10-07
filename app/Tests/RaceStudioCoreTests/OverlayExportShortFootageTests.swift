import Foundation
import Testing
@testable import RaceStudioCore

/// An export whose footage ends before its plan says (issue 204) — the file
/// changed after it was planned — fails as ``OverlayExportError/sourceUnreadable``
/// ("The video can't be read"), not as a writer failure, and leaves no file.
/// Frames dropped in the read itself are `ExportShortReadTests`.
@Suite(.enabled(if: VideoTests.isEnabled, VideoTests.skipReason)) struct OverlayExportShortFootageTests {

    /// The plan of a 90-frame clip, then the clip replaced by one of `frames`.
    private func shortened(to frames: Int, in sandbox: ExportSandbox) async throws -> ExportPlan {
        let footage = try await sandbox.footage(TestMediaFactory.Spec(frames: 90))
        let plan = try await exportPlan(footage)
        try FileManager.default.removeItem(at: footage)
        try await TestMediaFactory.writeMovie(TestMediaFactory.Spec(frames: frames), to: footage)
        return plan
    }

    private func overlay() async throws -> ExportOverlay {
        ExportOverlay(drawer: SessionTimeBar(origin: 0), telemetry: try await SessionTimeBar.timeline(from: -100,
                                                                                                       to: 100))
    }

    /// The error the export ends with, or `nil` when it finishes.
    private func failure(of stream: AsyncThrowingStream<ExportProgress, Error>) async -> OverlayExportError? {
        do {
            _ = try await collect(stream)
            return nil
        } catch {
            return error as? OverlayExportError
        }
    }

    @Test func test_footage_that_ends_before_its_plan_fails_and_leaves_no_file() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await shortened(to: 10, in: sandbox)

        let error = await failure(of: sandbox.exporter().export(plan, overlay: try await overlay(),
                                                                to: sandbox.destination))

        #expect(error == .sourceUnreadable)
        #expect(!sandbox.destinationExists)
        #expect(!sandbox.scratchExists, "the scratch directory is removed")
    }

    @Test func test_an_existing_destination_survives_footage_that_ends_early() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await shortened(to: 10, in: sandbox)
        let older = Data("an older export".utf8)
        try older.write(to: sandbox.destination)

        let error = await failure(of: sandbox.exporter().export(plan, overlay: try await overlay(),
                                                                to: sandbox.destination))

        #expect(error == .sourceUnreadable)
        #expect(try Data(contentsOf: sandbox.destination) == older)
    }
}
