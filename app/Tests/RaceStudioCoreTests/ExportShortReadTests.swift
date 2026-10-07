import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import RaceStudioCore

/// A read that hands the encoder fewer frames than the plan (issue 204) fails
/// the export as ``OverlayExportError/sourceUnreadable`` instead of finishing a
/// truncated video. AVFoundation drops a frame whose composition request is
/// finished as cancelled and still ends the read `.completed`, with no error —
/// how a CI virtual machine once wrote 4 of 45 frames and called it a success.
/// The plan promises its frame count within one frame, so one frame short
/// still exports and two short does not.
@Suite(.enabled(if: VideoTests.isEnabled, VideoTests.skipReason)) struct ExportShortReadTests {

    /// Run a pipeline over a 90-frame clip whose frames are composed by
    /// `compositor`; the frames it wrote, and its file.
    private func run(with compositor: FrameDroppingCompositor.Type,
                     in sandbox: ExportSandbox) async throws -> (frames: Int, file: URL) {
        let plan = try await exportPlan(try await sandbox.footage(TestMediaFactory.Spec(frames: 90)))
        let overlay = ExportOverlay(drawer: SessionTimeBar(origin: 0),
                                    telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))
        let composition = try await OverlayComposition.make(plan: plan, overlay: overlay)
        composition.videoComposition.customVideoCompositorClass = compositor
        let file = sandbox.directory.appendingPathComponent("out.mp4")
        let pipeline = try await ExportPipeline(composition: composition, plan: plan, writingTo: file)
        #expect(plan.frameCount == 90)
        try await pipeline.run()
        return (pipeline.framesWritten, file)
    }

    @Test func test_a_read_that_drops_most_frames_fails_as_unreadable() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }

        await #expect(throws: OverlayExportError.sourceUnreadable) {
            try await run(with: KeepsTenFrames.self, in: sandbox)
        }
    }

    @Test func test_one_frame_short_still_exports() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }

        let result = try await run(with: DropsTheLastFrame.self, in: sandbox)

        #expect(result.frames == 89)
        #expect(FileManager.default.fileExists(atPath: result.file.path))
    }

    @Test func test_two_frames_short_fails_as_unreadable() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }

        await #expect(throws: OverlayExportError.sourceUnreadable) {
            try await run(with: DropsTheLastTwoFrames.self, in: sandbox)
        }
    }
}

/// Passes the first ``keptFrames`` source frames through and finishes every
/// later request as cancelled, which AVFoundation answers by dropping it.
class FrameDroppingCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    class var keptFrames: Int { 90 }

    var sourcePixelBufferAttributes: CompositorPixelBufferAttributes? { OverlayCompositor.bgraAttributes }

    var requiredPixelBufferAttributesForRenderContext: CompositorPixelBufferAttributes {
        OverlayCompositor.bgraAttributes
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let index = Int((request.compositionTime.seconds * 30).rounded())
        guard index < Self.keptFrames,
              let instruction = request.videoCompositionInstruction as? OverlayCompositionInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finishCancelledRequest()
            return
        }
        request.finish(withComposedVideoFrame: source)
    }
}

final class KeepsTenFrames: FrameDroppingCompositor, @unchecked Sendable {
    override static var keptFrames: Int { 10 }
}

final class DropsTheLastFrame: FrameDroppingCompositor, @unchecked Sendable {
    override static var keptFrames: Int { 89 }
}

final class DropsTheLastTwoFrames: FrameDroppingCompositor, @unchecked Sendable {
    override static var keptFrames: Int { 88 }
}
