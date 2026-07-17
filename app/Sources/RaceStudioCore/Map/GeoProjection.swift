import CoreGraphics
import Foundation

/// A WGS84 latitude/longitude sample (issue 4.3).
public struct GPSCoord: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// An equirectangular projection about a track's centroid, auto-fitted to a
/// target rect with the aspect ratio preserved (issue 4.3).
///
/// Longitude is scaled by `cos(centroidLatitude)` so a degree east and a degree
/// north cover comparable ground near the track; the fit then applies a single
/// uniform scale so the racing line is never stretched. Latitude increases
/// north, which maps to *decreasing* y (screen up).
public struct GeoProjection: Equatable, Sendable {
    public let centroidLatitude: Double
    public let centroidLongitude: Double
    public let cosLatitude: Double
    public let scale: Double
    public let rawMinX: Double
    public let rawMaxY: Double
    public let originX: Double
    public let originY: Double

    /// Fits a projection to `coords`, centering the racing line in `rect` with a
    /// single uniform scale (aspect preserved). A degenerate (single-point or
    /// zero-span) set collapses to the rect center without dividing by zero.
    public static func fit(to coords: [GPSCoord],
                           in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> GeoProjection {
        // No coordinates → a projection that maps everything to the rect center.
        guard let first = coords.first else {
            return GeoProjection(centroidLatitude: 0, centroidLongitude: 0, cosLatitude: 1,
                                 scale: 0, rawMinX: 0, rawMaxY: 0,
                                 originX: Double(rect.midX), originY: Double(rect.midY))
        }

        var latMin = first.latitude, latMax = first.latitude
        var lonMin = first.longitude, lonMax = first.longitude
        for coord in coords {
            latMin = min(latMin, coord.latitude); latMax = max(latMax, coord.latitude)
            lonMin = min(lonMin, coord.longitude); lonMax = max(lonMax, coord.longitude)
        }

        let centroidLat = (latMin + latMax) / 2
        let centroidLon = (lonMin + lonMax) / 2
        let cosLat = cos(centroidLat * .pi / 180)

        // Raw planar bounds (longitude scaled by cos(centroidLatitude)).
        let x0 = (lonMin - centroidLon) * cosLat
        let x1 = (lonMax - centroidLon) * cosLat
        let rawMinX = min(x0, x1), rawMaxX = max(x0, x1)
        let rawMinY = latMin - centroidLat, rawMaxY = latMax - centroidLat
        let spanX = rawMaxX - rawMinX, spanY = rawMaxY - rawMinY

        // A single uniform scale fits the limiting axis; a zero-span axis is
        // ignored, and a fully degenerate set collapses to the center (scale 0).
        let scaleX = spanX > 0 ? Double(rect.width) / spanX : .infinity
        let scaleY = spanY > 0 ? Double(rect.height) / spanY : .infinity
        var scale = min(scaleX, scaleY)
        if !scale.isFinite { scale = 0 }

        let originX = Double(rect.minX) + (Double(rect.width) - spanX * scale) / 2
        let originY = Double(rect.minY) + (Double(rect.height) - spanY * scale) / 2

        return GeoProjection(centroidLatitude: centroidLat, centroidLongitude: centroidLon,
                             cosLatitude: cosLat, scale: scale, rawMinX: rawMinX, rawMaxY: rawMaxY,
                             originX: originX, originY: originY)
    }

    /// Maps a coordinate into the fitted planar rect (north maps to the top).
    public func project(_ coord: GPSCoord) -> CGPoint {
        let rawX = (coord.longitude - centroidLongitude) * cosLatitude
        let rawY = coord.latitude - centroidLatitude
        let x = originX + (rawX - rawMinX) * scale
        let y = originY + (rawMaxY - rawY) * scale // flip so higher latitude is up
        return CGPoint(x: x, y: y)
    }
}
