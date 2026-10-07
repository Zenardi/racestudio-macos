import AVFoundation
import Foundation

/// An export plan as AVFoundation media (issue 9.13): the planned footage
/// range — and, when kept, the sound under it — cut into a composition that
/// starts at zero, with a video composition that renders every frame at the
/// output size through the ``OverlayCompositor``.
///
/// Frame timing follows the footage track (`sourceTrackIDForFrameTiming`), so
/// composition frame `j` is footage frame `firstFrame + j`, at the footage's
/// exact rational time.
///
/// The composition renders in **Rec. 709 SDR**, what 8-bit H.264 and HEVC
/// players expect: Rec. 709 footage — every action camera's — passes through
/// unconverted, and AVFoundation converts anything else (BT.601, HDR) into it
/// before the compositor sees a frame.
struct OverlayComposition {
    /// The trimmed footage, starting at time zero.
    let asset: AVMutableComposition
    /// How each frame is rendered: the overlay compositor, at the output size.
    let videoComposition: AVMutableVideoComposition

    /// Build the composition of `plan`, drawing `overlay`.
    /// - Throws: ``OverlayExportError/noVideoTrack`` when the footage has no
    ///   video; whatever AVFoundation throws while reading it.
    static func make(plan: ExportPlan, overlay: ExportOverlay) async throws -> OverlayComposition {
        let footage = AVURLAsset(url: plan.request.source)
        guard let video = try await footage.loadTracks(withMediaType: .video).first else {
            throw OverlayExportError.noVideoTrack
        }
        let range = plan.sourceRange
        let asset = AVMutableComposition()
        let videoTrack = try addTrack(.video, to: asset)
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        if plan.includesAudio, let audio = try await footage.loadTracks(withMediaType: .audio).first {
            let heard = CMTimeRangeGetIntersection(range, otherRange: try await audio.load(.timeRange))
            if heard.duration > .zero {
                try addTrack(.audio, to: asset).insertTimeRange(heard, of: audio, at: heard.start - range.start)
            }
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = OverlayCompositor.self
        videoComposition.renderSize = plan.outputSize
        videoComposition.frameDuration = CMTime(value: CMTimeValue(plan.footage.frameRate.denominator),
                                                timescale: CMTimeScale(plan.footage.frameRate.numerator))
        videoComposition.sourceTrackIDForFrameTiming = videoTrack.trackID
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = [
            OverlayCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: range.duration),
                                          trackID: videoTrack.trackID,
                                          context: OverlayRenderContext(plan: plan, overlay: overlay))
        ]
        return OverlayComposition(asset: asset, videoComposition: videoComposition)
    }

    private static func addTrack(_ type: AVMediaType, to asset: AVMutableComposition) throws
        -> AVMutableCompositionTrack {
        guard let track = asset.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw OverlayExportError.writerFailed("Could not add a \(type.rawValue) track to the export.") }
        return track
    }
}
