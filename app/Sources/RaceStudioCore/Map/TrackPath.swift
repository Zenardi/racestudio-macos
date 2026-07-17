import CoreGraphics

/// Builds and queries the racing-line polyline from projected points (issue 4.3).
public enum TrackPath {
    /// The ordered polyline of the finite points in `points` (non-finite points
    /// — e.g. from a GPS dropout — are dropped, so the result may be shorter than
    /// the input and its indices no longer align with the original per-sample
    /// arrays). Use it for drawing; drive the cursor marker / color-by-channel
    /// from the original coordinate index instead.
    public static func build(from points: [CGPoint]) -> [CGPoint] {
        points.filter { $0.x.isFinite && $0.y.isFinite }
    }

    /// Whether the path forms a closed loop: it has at least two points and its
    /// first and last coincide within `tolerance`.
    public static func isClosed(_ path: [CGPoint], tolerance: CGFloat) -> Bool {
        guard path.count >= 2, let first = path.first, let last = path.last else { return false }
        return hypot(last.x - first.x, last.y - first.y) <= tolerance
    }

    /// The point at `index` along `path`, or `nil` when the index is out of
    /// range — the marker position for a cursor sample.
    public static func point(on path: [CGPoint], at index: Int) -> CGPoint? {
        path.indices.contains(index) ? path[index] : nil
    }

    /// The index of the path point nearest `point` (ties resolve to the lower
    /// index), or `nil` for an empty path — used to turn a click on the map into
    /// a cursor sample.
    public static func nearestIndex(to point: CGPoint, in path: [CGPoint]) -> Int? {
        guard !path.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = CGFloat.infinity
        for (index, candidate) in path.enumerated() {
            let distance = hypot(candidate.x - point.x, candidate.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }
}
