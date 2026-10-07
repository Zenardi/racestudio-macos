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
///
/// A cancel keeps AVFoundation’s contract (issue 203): it finishes every
/// request still waiting as cancelled and **blocks** until the frame being
/// composed, if any, is finished — so no request outlives the read that
/// asked for it.
public final class OverlayCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    /// 32-bit BGRA in IOSurfaces Metal can read: the format the overlay is
    /// drawn in and Core Image composes fastest.
    static let bgraAttributes: CompositorPixelBufferAttributes = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private let queue = DispatchQueue(label: "com.racestudio.overlay-compositor", qos: .userInitiated)
    /// Marks ``queue``, so a cancel made on it does not wait for itself.
    private let onQueue = DispatchSpecificKey<Void>()
    /// Confined to ``queue``.
    private let composer = OverlayFrameComposer()
    /// The requests started and not yet taken up by ``queue``, oldest first.
    private let waiting = OSAllocatedUnfairLock(initialState: [PendingRequest]())

    override public init() {
        super.init()
        queue.setSpecific(key: onQueue, value: ())
    }

    public var sourcePixelBufferAttributes: CompositorPixelBufferAttributes? { Self.bgraAttributes }

    public var requiredPixelBufferAttributesForRenderContext: CompositorPixelBufferAttributes { Self.bgraAttributes }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        waiting.withLock { $0.append(PendingRequest(request: request)) }
        queue.async { self.composeNext() }
    }

    /// Finish every waiting request as cancelled, then wait for the frame
    /// being composed: AVFoundation tears the read down once this returns,
    /// so it must leave no request unfinished.
    public func cancelAllPendingVideoCompositionRequests() {
        let cancelled = waiting.withLock { requests in
            defer { requests.removeAll() }
            return requests
        }
        for pending in cancelled { pending.request.finishCancelledRequest() }
        if DispatchQueue.getSpecific(key: onQueue) == nil { queue.sync {} }
    }

    // MARK: - Internals

    /// Compose the oldest waiting request, on ``queue`` — unless a cancel has
    /// already finished it.
    private func composeNext() {
        guard let next = waiting.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { return }
        autoreleasepool { compose(next.request) }
    }

    private func compose(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? OverlayCompositionInstruction else {
            request.finish(with: OverlayExportError.writerFailed("The export's video composition is not an overlay's."))
            return
        }
        // No source frame: the footage ended before the plan or could not be
        // decoded — the video can't be read (issue 204), not a writer failure.
        guard let source = request.sourceFrame(byTrackID: instruction.trackID) else {
            request.finish(with: OverlayExportError.sourceUnreadable)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: OverlayExportError.writerFailed("A video frame could not be made for the overlay."))
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
