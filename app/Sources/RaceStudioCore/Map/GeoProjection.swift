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
    /// - Parameters:
    ///   - coords: the coordinates to frame.
    ///   - rect: the target rect.
    ///   - trimmingFraction: the fraction of each axis's extremes to exclude when
    ///     computing the bounds, `0` (the default) for the plain min/max. A logger's
    ///     opening fixes are often hundreds of metres out — one such fix framed a
    ///     200 m circuit across 1232 m — so the map passes a small fraction to frame
    ///     what was actually driven. An axis is only trimmed when it has such
    ///     outliers (``outlierExtentRatio``), so a clean lap is framed whole.
    ///     Ignored below ``minimumPointsToTrim`` points, where there is no
    ///     distribution to trim.
    public static func fit(to coords: [GPSCoord],
                           in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                           trimmingFraction: Double = 0) -> GeoProjection {
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
        if let trimmed = trimmedBounds(coords, fraction: trimmingFraction) {
            latMin = trimmed.latMin; latMax = trimmed.latMax
            lonMin = trimmed.lonMin; lonMax = trimmed.lonMax
        } else {
            for coord in coords {
                latMin = min(latMin, coord.latitude); latMax = max(latMax, coord.latitude)
                lonMin = min(lonMin, coord.longitude); lonMax = max(lonMax, coord.longitude)
            }
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

    /// Below this many points there is no distribution to trim, so trimming is
    /// skipped and the plain min/max is used — otherwise a short trace would lose
    /// real data.
    public static let minimumPointsToTrim = 20

    /// Per-axis quantile bounds, or `nil` when trimming does not apply (a
    /// non-positive fraction, or too few points). Each axis is trimmed
    /// independently, and only when it has outliers (``trimmedAxis``).
    private static func trimmedBounds(_ coords: [GPSCoord], fraction: Double) -> Bounds? {
        guard fraction > 0, fraction.isFinite, coords.count >= minimumPointsToTrim else { return nil }
        // Clamp so an absurd fraction still leaves a non-empty interval.
        let clamped = min(fraction, 0.45)
        let lats = coords.map(\.latitude).sorted()
        let lons = coords.map(\.longitude).sorted()
        let low = Int((Double(coords.count - 1) * clamped).rounded(.down))
        let high = coords.count - 1 - low
        guard low < high else { return nil }
        let (latMin, latMax) = trimmedAxis(lats, low: low, high: high)
        let (lonMin, lonMax) = trimmedAxis(lons, low: low, high: high)
        return Bounds(latMin: latMin, latMax: latMax, lonMin: lonMin, lonMax: lonMax)
    }

    /// How much wider an axis's full extent must be than its trimmed extent before
    /// the trim is applied. Below this the extremes are the circuit itself — on a
    /// real lap the hairpin tips, where a slowing kart bunches its fixes, so a 5%
    /// trim cut 8–10% off each axis and clipped them out of the pane. Above it they
    /// are an excursion: a whole session measured 4.3x its trimmed extent N–S.
    public static let outlierExtentRatio = 1.25

    /// One sorted axis's bounds: trimmed to `[low, high]` only when the full extent
    /// is more than ``outlierExtentRatio`` times the trimmed one.
    private static func trimmedAxis(_ sorted: [Double], low: Int, high: Int) -> (Double, Double) {
        let full = (sorted[0], sorted[sorted.count - 1])
        let trimmedSpan = sorted[high] - sorted[low]
        guard trimmedSpan > 0, (full.1 - full.0) > trimmedSpan * outlierExtentRatio else { return full }
        return (sorted[low], sorted[high])
    }

    /// A coordinate bounding box. A named type rather than a tuple so the bounds
    /// cannot be assembled in the wrong order at a call site.
    private struct Bounds {
        let latMin: Double
        let latMax: Double
        let lonMin: Double
        let lonMax: Double
    }

    /// Maps a coordinate into the fitted planar rect (north maps to the top).
    public func project(_ coord: GPSCoord) -> CGPoint {
        let rawX = (coord.longitude - centroidLongitude) * cosLatitude
        let rawY = coord.latitude - centroidLatitude
        return CGPoint(x: translateX + rawX * scale, y: translateY - rawY * scale)
    }

    /// The inverse of ``project(_:)`` — the coordinate a view point corresponds to.
    ///
    /// Needed to tell a real map which ground the plot is showing (see
    /// ``GeoRegion/covering(_:size:)``). A degenerate projection (``scale`` 0, from a
    /// coordinate-less or single-point session) has no inverse; it reports the
    /// centroid rather than dividing by zero.
    public func unproject(_ point: CGPoint) -> GPSCoord {
        guard scale > 0, scale.isFinite else {
            return GPSCoord(latitude: centroidLatitude, longitude: centroidLongitude)
        }
        let rawX = (Double(point.x) - translateX) / scale
        let rawY = (translateY - Double(point.y)) / scale
        // cosLatitude is cos of a latitude, so it is only zero exactly at a pole —
        // guarded anyway so a bad projection cannot produce an infinite longitude.
        let lon = cosLatitude != 0 ? centroidLongitude + rawX / cosLatitude : centroidLongitude
        return GPSCoord(latitude: centroidLatitude + rawY, longitude: lon)
    }
}

/// The geographic region a view shows — the centre and full angular span, the shape
/// a map view is configured with.
///
/// Derived by inverting a fitted ``GeoProjection`` at the view's corners, so the
/// imagery underneath the racing line covers exactly the ground the line was drawn
/// for. Deriving it rather than choosing a zoom level is what keeps the two aligned
/// when the pane is resized.
public struct GeoRegion: Equatable, Sendable {
    /// The region's centre.
    public let center: GPSCoord
    /// Full north–south span, in degrees of latitude.
    public let latitudeDelta: Double
    /// Full east–west span, in degrees of longitude.
    public let longitudeDelta: Double

    public init(center: GPSCoord, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// The region `projection` shows across a view of `size`, or `nil` when there is
    /// nothing to frame — a zero/non-finite size, or a degenerate projection from a
    /// session with no GPS (or a single fix, which has no extent).
    public static func covering(_ projection: GeoProjection, size: CGSize) -> GeoRegion? {
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite,
              projection.scale > 0, projection.scale.isFinite else { return nil }
        let topLeft = projection.unproject(.zero)
        let bottomRight = projection.unproject(CGPoint(x: size.width, y: size.height))
        let latitudeDelta = abs(topLeft.latitude - bottomRight.latitude)
        let longitudeDelta = abs(bottomRight.longitude - topLeft.longitude)
        guard latitudeDelta.isFinite, longitudeDelta.isFinite,
              latitudeDelta > 0, longitudeDelta > 0 else { return nil }
        return GeoRegion(
            center: GPSCoord(latitude: (topLeft.latitude + bottomRight.latitude) / 2,
                             longitude: (topLeft.longitude + bottomRight.longitude) / 2),
            latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
}
