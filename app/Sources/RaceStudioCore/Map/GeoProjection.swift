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
    /// Folded translation terms: `x = translateX + rawX·scale`,
    /// `y = translateY − rawY·scale` (north up).
    public let translateX: Double
    public let translateY: Double

    /// Fits a projection to `coords`, centering the racing line in `rect` with a
    /// single uniform scale (aspect preserved). A degenerate (single-point or
    /// zero-span) set — or a null / non-finite `rect` — collapses to a finite
    /// point without dividing by zero or producing an infinite origin.
    public static func fit(to coords: [GPSCoord],
                           in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> GeoProjection {
        // A null rect (e.g. `insetBy` larger than the view) or a non-finite one
        // has no usable center; map everything to the origin.
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite else {
            return GeoProjection(centroidLatitude: 0, centroidLongitude: 0, cosLatitude: 1,
                                 scale: 0, translateX: 0, translateY: 0)
        }
        let midX = Double(rect.minX) + Double(rect.width) / 2
        let midY = Double(rect.minY) + Double(rect.height) / 2

        // No coordinates → a projection that maps everything to the rect center.
        guard let first = coords.first else {
            return GeoProjection(centroidLatitude: 0, centroidLongitude: 0, cosLatitude: 1,
                                 scale: 0, translateX: midX, translateY: midY)
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

        let originX = midX - spanX * scale / 2
        let originY = midY - spanY * scale / 2
        return GeoProjection(centroidLatitude: centroidLat, centroidLongitude: centroidLon,
                             cosLatitude: cosLat, scale: scale,
                             translateX: originX - rawMinX * scale,
                             translateY: originY + rawMaxY * scale)
    }

    /// Maps a coordinate into the fitted planar rect (north maps to the top).
    public func project(_ coord: GPSCoord) -> CGPoint {
        let rawX = (coord.longitude - centroidLongitude) * cosLatitude
        let rawY = coord.latitude - centroidLatitude
        return CGPoint(x: translateX + rawX * scale, y: translateY - rawY * scale)
    }
}
