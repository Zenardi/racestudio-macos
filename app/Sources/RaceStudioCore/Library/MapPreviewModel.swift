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
    /// Fixes outside the framed region (a stray trail) fall outside the rect.
    public let points: [CGPoint]

    /// Where the framed region — the circuit, without stray fixes — lies among
    /// ``points``. ``fitted(in:inset:)`` scales this, not every point, to the view.
    public let frame: CGRect

    /// Fit `coordinates` into `rect` (default the unit box) with ``GeoProjection``.
    /// Fewer than two coordinates yields no points — there is no line to stroke.
    public init(coordinates: [GPSCoord],
                in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        guard coordinates.count >= 2,
              let region = GeoProjection.framedRegion(of: coordinates, trimmingFraction: GeoProjection.framingTrim)
        else {
            self.points = []
            self.frame = .zero
            return
        }
        let projection = GeoProjection.fit(to: coordinates, in: rect, trimmingFraction: GeoProjection.framingTrim)
        self.points = coordinates.map(projection.project)
        let corner = projection.project(GPSCoord(
            latitude: region.center.latitude - region.latitudeDelta / 2,
            longitude: region.center.longitude - region.longitudeDelta / 2))
        let opposite = projection.project(GPSCoord(
            latitude: region.center.latitude + region.latitudeDelta / 2,
            longitude: region.center.longitude + region.longitudeDelta / 2))
        self.frame = CGRect(x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
                            width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y))
    }

    /// Whether there is a racing line to draw: fewer than two points, or points
    /// that all sit on one spot, is nothing.
    public var isEmpty: Bool { points.count < 2 || (frame.width == 0 && frame.height == 0) }

    /// The points laid out in `rect`, scaled **uniformly** so the track keeps
    /// its real shape, with the framed circuit (``frame``) centred `inset` from
    /// every edge. Fixes outside the framed region (a stray trail) land outside
    /// the rect; ``visibleRuns(in:inset:)`` leaves them out of the drawing.
    ///
    /// Scaling x by the view's width and y by its height separately would
    /// stretch a circuit to the box's proportions — a wide preview pane turned
    /// a compact kart track into a long smear. One scale for both axes, set by
    /// whichever side runs out first, keeps the drawing true to the ground. A
    /// straight line (no height) spans the width at mid-height. Returns no
    /// points when there is nothing to draw or the box is smaller than its
    /// insets.
    public func fitted(in rect: CGRect, inset: CGFloat) -> [CGPoint] {
        let available = rect.insetBy(dx: inset, dy: inset)
        guard !isEmpty, !available.isNull, available.width > 0, available.height > 0 else { return [] }

        let minX = frame.minX, minY = frame.minY
        let spanX = frame.width, spanY = frame.height
        let scaleX = spanX > 0 ? available.width / spanX : .infinity
        let scaleY = spanY > 0 ? available.height / spanY : .infinity
        let scale = min(scaleX, scaleY)
        guard scale.isFinite else { return [] } // every point identical

        let offsetX = available.midX - spanX * scale / 2
        let offsetY = available.midY - spanY * scale / 2
        return points.map { point in
            CGPoint(x: offsetX + (point.x - minX) * scale, y: offsetY + (point.y - minY) * scale)
        }
    }

    /// The fitted line split into the runs to draw: only fixes within the
    /// framed circuit (plus the inset margin), with a break wherever the line
    /// leaves it — so a trail recorded off the circuit adds no stray segment
    /// cutting in from the edge. Runs of fewer than two points are dropped.
    public func visibleRuns(in rect: CGRect, inset: CGFloat) -> [[CGPoint]] {
        // The whole view: the framed circuit plus its inset margin (a hair of
        // slack so a hairpin tip exactly on the edge still counts).
        let bounds = rect.insetBy(dx: -0.5, dy: -0.5)
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for point in fitted(in: rect, inset: inset) {
            if bounds.contains(point) {
                current.append(point)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        runs.append(current)
        return runs.filter { $0.count >= 2 }
    }
}
