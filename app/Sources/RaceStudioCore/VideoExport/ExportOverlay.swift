import CoreGraphics
import Foundation

/// What draws an export's overlay into each frame (issue 9.13): in the app,
/// the ``OverlayRenderer`` the live HUD uses, so the preview is what is
/// exported. A seam, so the engine's tests can draw a test overlay instead.
public protocol OverlayFrameDrawing: Sendable {
    /// Build whatever is drawn the same on every frame of `size` pixels —
    /// called once per output size, before the first frame.
    func prepare(for size: CGSize)

    /// Draw `frame` into `context`, a premultiplied BGRA sRGB bitmap of `size`
    /// pixels in its default drawing space, clearing it first: every pixel
    /// the overlay does not cover must be left transparent.
    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize)
}

extension OverlayRenderer: OverlayFrameDrawing {}

/// The overlay an export burns in (issue 9.13): what draws it, and the
/// telemetry it is drawn from, sampled at each frame's session time.
public struct ExportOverlay: Sendable {
    /// What draws the overlay — the app's ``OverlayRenderer``.
    public let drawer: any OverlayFrameDrawing
    /// The session's telemetry.
    public let telemetry: TelemetryTimeline

    public init(drawer: any OverlayFrameDrawing, telemetry: TelemetryTimeline) {
        self.drawer = drawer
        self.telemetry = telemetry
    }
}
