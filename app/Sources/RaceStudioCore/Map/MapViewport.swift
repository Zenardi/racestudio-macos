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
    /// How far in the user may zoom without map imagery. With imagery the map's
    /// own limit usually applies first (see ``limitZoom(to:)``).
    public static let maximumZoom = 32.0
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

    /// Lower the zoom to at most `limit` — used when the map imagery cannot show
    /// anything closer, so the zoom buttons stay honest. Never zooms back in.
    public mutating func limitZoom(to limit: Double) {
        guard limit.isFinite, limit > 0 else { return }
        zoom = min(zoom, max(limit, Self.minimumZoom))
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

public extension GeoProjection {
    /// This projection with its scale capped at `maximumScale` (pixels per degree
    /// of latitude), shrinking about `center` — how a map that refuses to zoom any
    /// closer widens its view. Unchanged when already within the limit, or when the
    /// limit is not a positive finite number.
    func limited(toScale maximumScale: Double, about center: CGPoint) -> GeoProjection {
        guard maximumScale.isFinite, maximumScale > 0, scale > maximumScale else { return self }
        let factor = maximumScale / scale
        let centerX = Double(center.x), centerY = Double(center.y)
        return GeoProjection(centroidLatitude: centroidLatitude, centroidLongitude: centroidLongitude,
                             cosLatitude: cosLatitude, scale: maximumScale,
                             translateX: (translateX - centerX) * factor + centerX,
                             translateY: (translateY - centerY) * factor + centerY)
    }
}

public extension GeoRegion {
    /// The widest span (degrees of latitude) that can be a zoom *limit*. MapKit's
    /// closest zoom is around half a metre per point, so a settled widening spans
    /// metres to kilometres; a map not laid out yet reports tens of degrees.
    static let maximumLimitSpan = 0.1

    /// How far (as a fraction of the requested span) a widened region's centre may
    /// sit from the request's — MapKit widens about the centre it was given.
    static let limitCentreTolerance = 0.05

    /// The scale (pixels per degree of latitude) at which this region fills a view
    /// `height` points tall, or `nil` for a non-positive height.
    func scale(forHeight height: Double) -> Double? {
        guard height > 0, height.isFinite, latitudeDelta > 0 else { return nil }
        return height / latitudeDelta
    }

    /// The imagery's zoom limit (pixels per degree of latitude) revealed by the map
    /// showing this region when asked for `request` in a view of `size`, or `nil`
    /// when it showed what was asked — or when this is not a settled widening of
    /// the request at all (a whole-world region from a map not laid out yet, or a
    /// stale region centred somewhere else), which must never be taken as a limit.
    func zoomLimit(forRequest request: GeoProjection, in size: CGSize) -> Double? {
        guard let shown = scale(forHeight: Double(size.height)),
              let asked = GeoRegion.covering(request, size: size),
              latitudeDelta < Self.maximumLimitSpan,
              shown < request.scale * 0.995 else { return nil }
        let tolerance = asked.latitudeDelta * Self.limitCentreTolerance
        guard abs(center.latitude - asked.center.latitude) <= tolerance,
              abs(center.longitude - asked.center.longitude) <= asked.longitudeDelta * Self.limitCentreTolerance
        else { return nil }
        return shown
    }
}
