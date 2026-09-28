import CoreGraphics
import Foundation

/// Map imagery for the track map's backdrop: which ground to fetch, and where a
/// fetched image goes under the racing line at any zoom and pan.
///
/// The imagery is a still snapshot rather than a live map view. A live `MKMapView`
/// will not zoom past ~0.54 m per point and silently shows a wider region instead,
/// so the line and the ground under it drew at different scales and the zoom
/// buttons had to be capped to hide it. A snapshot is simply scaled along with the
/// line: past the imagery's own resolution it gets softer, never misaligned.
public enum MapImagery {

    /// One snapshot to fetch: the ground it covers and its size in points.
    public struct Request: Equatable, Sendable {
        public let region: GeoRegion
        public let size: CGSize
    }

    /// The side of the fine layer's square, as a multiple of the lap's larger
    /// extent — the circuit plus its run-off at full detail.
    public static let detailCoverage = 1.6
    /// The side of the coarse layer's square — enough ground that zooming out to
    /// ``MapViewport/minimumZoom`` in a wide pane still has imagery at the edges.
    public static let contextCoverage = 8.0
    /// The fine layer's size in points: about half a metre per point on a 600 m
    /// square, the closest satellite imagery goes.
    public static let detailSize = 2048.0
    /// The coarse layer's size in points.
    public static let contextSize = 1024.0
    /// The smallest extent (metres) the imagery is sized for, so a single fix or a
    /// few metres of pit lane still gets a readable neighbourhood.
    public static let minimumExtent = 50.0

    /// Metres per degree of latitude (and of longitude at the equator).
    private static let metresPerDegree = 111_320.0

    /// The snapshots to fetch for a map framing `region`, coarsest first so the
    /// fine layer draws on top. Squares in metres around the region's centre, so
    /// every pane shape is covered. Empty for a non-finite region, or one at a pole.
    public static func requests(framing region: GeoRegion) -> [Request] {
        // `max` skips a NaN rather than propagating it, so check the inputs.
        guard [region.center.latitude, region.center.longitude, region.latitudeDelta, region.longitudeDelta]
            .allSatisfy(\.isFinite) else { return [] }
        let cosLat = cos(region.center.latitude * .pi / 180)
        let height = region.latitudeDelta * metresPerDegree
        let width = region.longitudeDelta * metresPerDegree * cosLat
        let extent = max(width, height, minimumExtent)
        guard cosLat > 0 else { return [] }
        return [(contextCoverage, contextSize), (detailCoverage, detailSize)].map { coverage, side in
            let metres = extent * coverage
            return Request(region: GeoRegion(center: region.center,
                                             latitudeDelta: metres / metresPerDegree,
                                             longitudeDelta: metres / (metresPerDegree * cosLat)),
                           size: CGSize(width: side, height: side))
        }
    }

    /// A fetched image and where two coordinates landed in it — all it takes to
    /// place the image under any projection, whatever region the map service
    /// actually rendered (it may widen what it was asked for).
    public struct Tile: Equatable, Sendable {
        /// The image's size, in points.
        public let size: CGSize
        /// Two coordinates, south-west and north-east of each other...
        public let southWest: GPSCoord
        public let northEast: GPSCoord
        /// ...and where they sit in the image, from its top-left corner.
        public let southWestPoint: CGPoint
        public let northEastPoint: CGPoint

        public init(size: CGSize, southWest: GPSCoord, southWestPoint: CGPoint,
                    northEast: GPSCoord, northEastPoint: CGPoint) {
            self.size = size
            self.southWest = southWest
            self.northEast = northEast
            self.southWestPoint = southWestPoint
            self.northEastPoint = northEastPoint
        }

        /// Where to draw the image so its ground lies under `projection`, or `nil`
        /// when the anchors cannot place it (coincident, or non-finite).
        ///
        /// Each axis is scaled independently from the two anchors, so an image
        /// that is a hair stretched against the projection (Mercator against the
        /// plot's equirectangular, a fraction of a pixel over a circuit) is still
        /// pinned at both anchors.
        public func frame(in projection: GeoProjection) -> CGRect? {
            let southWestView = projection.project(southWest)
            let northEastView = projection.project(northEast)
            let imageWidth = Double(northEastPoint.x - southWestPoint.x)
            let imageHeight = Double(northEastPoint.y - southWestPoint.y)
            guard imageWidth != 0, imageHeight != 0 else { return nil }
            let scaleX = Double(northEastView.x - southWestView.x) / imageWidth
            let scaleY = Double(northEastView.y - southWestView.y) / imageHeight
            let rect = CGRect(x: Double(southWestView.x) - Double(southWestPoint.x) * scaleX,
                              y: Double(southWestView.y) - Double(southWestPoint.y) * scaleY,
                              width: Double(size.width) * scaleX,
                              height: Double(size.height) * scaleY)
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            return rect
        }
    }
}
