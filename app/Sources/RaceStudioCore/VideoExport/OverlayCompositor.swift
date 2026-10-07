import AVFoundation
import CoreVideo
import Foundation
import os

#if compiler(>=6.0)
/// Pixel-buffer attributes as the SDK's `AVVideoCompositing` takes them
/// (`Sendable` values since the macOS 15 SDK).
public typealias CompositorPixelBufferAttributes = [String: any Sendable]
#else
public typealias CompositorPixelBufferAttributes = [String: Any]
#endif

/// The custom video compositor of the overlay export (issue 9.13): for each
/// frame AVFoundation asks for, it maps the frame's composition time through
/// the sync to session time, samples the telemetry, draws the overlay and
/// blends it over the source frame (``OverlayFrameComposer``).
///
/// AVFoundation instantiates it by class from the video composition
/// (``OverlayComposition``); each export's ``OverlayRenderContext`` reaches it
/// inside the ``OverlayCompositionInstruction``. Frames are composed one at a
/// time, in order, on a private serial queue — the sampling cursor sweeps
/// forward, and the overlay draw is serialized process-wide anyway.
public final class OverlayCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    /// 32-bit BGRA in IOSurfaces Metal can read: the format the overlay is
    /// drawn in and Core Image composes fastest.
    static let bgraAttributes: CompositorPixelBufferAttributes = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private let queue = DispatchQueue(label: "com.racestudio.overlay-compositor", qos: .userInitiated)
    /// Confined to ``queue``.
    private let composer = OverlayFrameComposer()
    /// Bumped by a cancel: requests queued before it are finished as cancelled.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    public var sourcePixelBufferAttributes: CompositorPixelBufferAttributes? { Self.bgraAttributes }

    public var requiredPixelBufferAttributesForRenderContext: CompositorPixelBufferAttributes { Self.bgraAttributes }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let ticket = generation.withLock { $0 }
        let pending = PendingRequest(request: request)
        queue.async {
            guard self.generation.withLock({ $0 }) == ticket else {
                pending.request.finishCancelledRequest()
                return
            }
            autoreleasepool { self.compose(pending.request) }
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
    }

    // MARK: - Internals

    private func compose(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? OverlayCompositionInstruction,
              let source = request.sourceFrame(byTrackID: instruction.trackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: OverlayExportError.writerFailed("A video frame could not be read for the overlay."))
            return
        }
        do {
            try composer.compose(source: source, at: request.compositionTime, context: instruction.context,
                                 into: output)
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }
}

/// A composition request handed to the compositor's queue. AVFoundation
/// requests may be finished from any thread.
private struct PendingRequest: @unchecked Sendable {
    let request: AVAsynchronousVideoCompositionRequest
}

/// The one instruction of an overlay export's video composition (issue 9.13):
/// the whole composition's time range, the footage track, and the export's
/// ``OverlayRenderContext``.
final class OverlayCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Every frame differs (the overlay moves), so none may be reused.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// The footage's track in the composition.
    let trackID: CMPersistentTrackID
    let context: OverlayRenderContext

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, context: OverlayRenderContext) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.context = context
    }
}
