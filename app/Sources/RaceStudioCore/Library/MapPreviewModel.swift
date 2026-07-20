import CoreGraphics
import Foundation

/// A lightweight racing-line thumbnail for the library browser preview (issue
/// 8.14): the session's GPS coordinates projected into a target rect (the unit
/// box by default), ready for the view to stroke as a path.
///
/// It reuses ``GeoProjection`` (aspect preserved, north up) but carries none of
/// the colour channel, distance axis, or cursor mapping of the full
/// ``TrackMapModel`` — so the browser can preview a session's shape without
/// opening the analysis workspace. A track of fewer than two coordinates has no
/// line to draw and reports ``isEmpty``.
public struct MapPreviewModel: Equatable, Sendable {

    /// The projected points, in fix order, laid out inside the fitting rect.
    public let points: [CGPoint]

    /// Fit `coordinates` into `rect` (default the unit box) with ``GeoProjection``.
    /// Fewer than two coordinates yields no points — there is no line to stroke.
    public init(coordinates: [GPSCoord],
                in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        guard coordinates.count >= 2 else {
            self.points = []
            return
        }
        let projection = GeoProjection.fit(to: coordinates, in: rect)
        self.points = coordinates.map(projection.project)
    }

    /// Whether there is a racing line to draw (fewer than two points is nothing).
    public var isEmpty: Bool { points.count < 2 }
}
