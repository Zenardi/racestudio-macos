import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal

/// Composes one export frame (issue 9.13): the source frame turned upright and
/// scaled to the output, with the overlay for **that frame's** session time
/// drawn at the output size and alpha-blended over it.
///
/// - **Core Image on Metal:** the scale and the blend run on the GPU; only the
///   overlay itself is drawn with CoreGraphics, into one reused pixel buffer.
///   Colour management is off, so the footage's pixels pass through untouched
///   outside the overlay and the overlay blends in the footage's own encoding,
///   as it does over the player in the live HUD.
/// - **Sequential:** the telemetry is sampled with one forward
///   ``SamplingCursor``, so a sweep through the footage costs O(1) per frame.
///
/// Not thread-safe: one composer per compositor, used from its serial queue.
final class OverlayFrameComposer {

    /// The Core Image context every composer renders with: Metal-backed when
    /// there is a GPU, colour management off. Thread-safe, so it is shared.
    static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                               .cacheIntermediates: false]
        return MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) }
            ?? CIContext(options: options)
    }()

    private let ciContext: CIContext
    private var cursor = SamplingCursor()
    private var overlayBuffer: CVPixelBuffer?
    private var prepared: (context: UUID, size: CGSize)?

    init(ciContext: CIContext = OverlayFrameComposer.sharedContext) {
        self.ciContext = ciContext
    }

    /// Render the frame at `compositionTime` — `source` and its overlay — into
    /// `output`, sized as `output` is.
    /// - Throws: ``OverlayExportError/writerFailed(_:)`` when the overlay
    ///   buffer cannot be made.
    func compose(source: CVPixelBuffer, at compositionTime: CMTime, context: OverlayRenderContext,
                 into output: CVPixelBuffer) throws {
        let size = CGSize(width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        prepare(context, size: size)
        var image = Self.upright(CIImage(cvPixelBuffer: source), rotation: context.rotation, in: size)
        if let frame = context.telemetryFrame(at: context.sessionTime(at: compositionTime), cursor: &cursor) {
            let overlay = try drawOverlay(frame, with: context.overlay.drawer, size: size)
            image = CIImage(cvPixelBuffer: overlay).composited(over: image)
        }
        ciContext.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
    }

    // MARK: - Internals

    /// Prepare the overlay for a new export or output size, and restart the
    /// telemetry sweep.
    private func prepare(_ context: OverlayRenderContext, size: CGSize) {
        if let prepared, prepared.context == context.id, prepared.size == size { return }
        context.overlay.drawer.prepare(for: size)
        cursor = SamplingCursor()
        prepared = (context.id, size)
    }

    /// `image` turned by `rotation`, scaled (Lanczos) to fill `size`, and
    /// cropped to it, with its origin at zero.
    static func upright(_ image: CIImage, rotation: FootageRotation, in size: CGSize) -> CIImage {
        var turned = image.oriented(rotation.imageOrientation)
        turned = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        let extent = turned.extent
        if extent.size != size, extent.width > 0, extent.height > 0 {
            let scale = size.height / extent.height
            turned = turned.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: size.width / extent.width / scale
            ])
        }
        return turned.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `frame` drawn into the reused overlay buffer, made for `size` if it is
    /// not that size yet.
    private func drawOverlay(_ frame: TelemetryFrame, with drawer: any OverlayFrameDrawing,
                             size: CGSize) throws -> CVPixelBuffer {
        let buffer = try overlayBuffer(for: size)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                                      height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: Self.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw OverlayExportError.writerFailed("Could not draw the overlay at \(size).")
        }
        drawer.draw(frame, in: context, size: size)
        return buffer
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private func overlayBuffer(for size: CGSize) throws -> CVPixelBuffer {
        if let overlayBuffer, CVPixelBufferGetWidth(overlayBuffer) == Int(size.width),
           CVPixelBufferGetHeight(overlayBuffer) == Int(size.height) {
            return overlayBuffer
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            OverlayCompositor.bgraAttributes as CFDictionary, &buffer)
        guard let buffer else { throw OverlayExportError.writerFailed("Could not allocate the overlay at \(size).") }
        overlayBuffer = buffer
        return buffer
    }
}

extension FootageRotation {
    /// The image orientation that shows a frame stored with this turn upright.
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: return .up
        case .clockwise90: return .right
        case .upsideDown: return .down
        case .counterclockwise90: return .left
        }
    }
}
