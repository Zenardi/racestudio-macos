import CoreGraphics
import Foundation

/// The user's zoom and pan on the track map, applied on top of the automatic fit.
///
/// Held as a zoom factor and an offset rather than as a region, so it survives the
/// fit changing underneath it — a pane resize or a new lap selection re-fits the
/// track and the user's "twice as close, a bit to the left" still means the same
/// thing. `zoom == 1` with no offset is the plain fit.
///
/// The offset is in *fitted* (unzoomed) points: the point of the fitted track
/// drawn at the view centre, measured from the view centre. Keeping it unzoomed is
/// what makes a drag move the ground exactly as far as the pointer at any zoom.
public struct MapViewport: Equatable, Sendable {

    /// How far out past the fit the user may zoom — a little context around the
    /// circuit, not a view of the whole region.
    public static let minimumZoom = 0.25
    /// How far in the user may zoom — a hairpin's kerbs filling the pane. Closer
    /// than this, GPS noise and the imagery's own resolution show nothing more.
    public static let maximumZoom = 10.0
    /// One press of zoom in / out.
    public static let zoomStep = 1.5
    /// One press of a pan arrow, as a fraction of the view.
    public static let panStepFraction = 0.2

    /// The magnification relative to the fit.
    public private(set) var zoom: Double = 1
    /// The fitted-track point shown at the view centre, relative to the centre.
    public private(set) var offset: CGSize = .zero

    public init() {}

    /// `true` for the plain automatic fit.
    public var isFitted: Bool { zoom == 1 && offset == .zero }

    public var canZoomIn: Bool { zoom < Self.maximumZoom }
    public var canZoomOut: Bool { zoom > Self.minimumZoom }

    /// A direction for the pan arrows: the way the *view* moves.
    public enum PanDirection: Sendable, CaseIterable {
        case up, down, left, right
    }

    /// Zoom in one step about the view centre.
    public mutating func zoomIn(in size: CGSize) {
        zoom(by: Self.zoomStep, anchor: Self.center(of: size), in: size)
    }

    /// Zoom out one step about the view centre.
    public mutating func zoomOut(in size: CGSize) {
        zoom(by: 1 / Self.zoomStep, anchor: Self.center(of: size), in: size)
    }

    /// Multiply the zoom by `factor`, keeping the ground under `anchor` (a pinch
    /// location, in view points) where it is. A non-finite or non-positive factor
    /// is ignored.
    public mutating func zoom(by factor: Double, anchor: CGPoint, in size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let center = Self.center(of: size)
        // The fitted point under the anchor, before and after, must coincide.
        let anchorX = (Double(anchor.x) - Double(center.x)) / zoom + Double(offset.width)
        let anchorY = (Double(anchor.y) - Double(center.y)) / zoom + Double(offset.height)
        let newZoom = min(max(zoom * factor, Self.minimumZoom), Self.maximumZoom)
        offset = CGSize(width: anchorX - (Double(anchor.x) - Double(center.x)) / newZoom,
                        height: anchorY - (Double(anchor.y) - Double(center.y)) / newZoom)
        zoom = newZoom
        clampOffset(in: size)
    }

    /// A mouse-wheel notch (a line of scroll) zooms by this factor.
    public static let wheelNotchZoom = 1.2
    /// A trackpad's precise scroll zooms by `e^(points × this)` — about a doubling
    /// for a 70-point swipe.
    public static let preciseScrollZoomRate = 0.01

    /// The zoom factor for one scroll event of `delta` (positive rolls the wheel
    /// away from the user, which zooms in, as on a map). A wheel reports lines, a
    /// trackpad points (`isPrecise`), so each has its own rate. A non-finite delta
    /// zooms nothing; a flung wheel is capped so one event cannot jump the whole range.
    public static func scrollZoomFactor(delta: Double, isPrecise: Bool) -> Double {
        guard delta.isFinite else { return 1 }
        if isPrecise { return exp(min(max(delta, -100), 100) * preciseScrollZoomRate) }
        return pow(wheelNotchZoom, min(max(delta, -5), 5))
    }

    /// Move the ground with a drag of `translation` view points.
    public mutating func pan(by translation: CGSize, in size: CGSize) {
        offset = CGSize(width: Double(offset.width) - Double(translation.width) / zoom,
                        height: Double(offset.height) - Double(translation.height) / zoom)
        clampOffset(in: size)
    }

    /// Move the view one arrow-press in `direction`.
    public mutating func panStep(_ direction: PanDirection, in size: CGSize) {
        let stepX = Double(size.width) * Self.panStepFraction
        let stepY = Double(size.height) * Self.panStepFraction
        // Moving the view left means the ground slides right under it.
        switch direction {
        case .left: pan(by: CGSize(width: stepX, height: 0), in: size)
        case .right: pan(by: CGSize(width: -stepX, height: 0), in: size)
        case .up: pan(by: CGSize(width: 0, height: stepY), in: size)
        case .down: pan(by: CGSize(width: 0, height: -stepY), in: size)
        }
    }

    /// Back to the plain fit.
    public mutating func reset() {
        zoom = 1
        offset = .zero
    }

    /// `projection` (the automatic fit for a view of `size`) with this zoom and
    /// pan applied.
    public func apply(to projection: GeoProjection, in size: CGSize) -> GeoProjection {
        guard !isFitted else { return projection }
        let center = Self.center(of: size)
        let centerX = Double(center.x), centerY = Double(center.y)
        return GeoProjection(
            centroidLatitude: projection.centroidLatitude,
            centroidLongitude: projection.centroidLongitude,
            cosLatitude: projection.cosLatitude,
            scale: projection.scale * zoom,
            translateX: (projection.translateX - centerX - Double(offset.width)) * zoom + centerX,
            translateY: (projection.translateY - centerY - Double(offset.height)) * zoom + centerY)
    }

    /// Keep the view centre within the fitted area, so the track can never be
    /// panned entirely out of sight.
    private mutating func clampOffset(in size: CGSize) {
        let halfWidth = Double(size.width) / 2, halfHeight = Double(size.height) / 2
        offset = CGSize(width: min(max(Double(offset.width), -halfWidth), halfWidth),
                        height: min(max(Double(offset.height), -halfHeight), halfHeight))
    }

    private static func center(of size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }
}
