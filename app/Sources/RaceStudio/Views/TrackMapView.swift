import SwiftUI
import RaceStudioCore

/// The GPS track map (issue 4.3): the racing line colored by a channel, sector
/// and mini-sector boundary marks, and a cursor marker.
///
/// Thin: every geometric decision — the `GeoProjection` fit, the `TrackPath`
/// polyline and nearest-point lookup, the `ChannelColorScale`, and the
/// `SectorModel` boundaries — is computed in `RaceStudioCore`. This view only
/// strokes the resulting path and dots into a `Canvas` and turns a click into a
/// cursor index (the shared 4.7 cursor supplies/consumes `cursorIndex`).
public struct TrackMapView: View {
    private let coords: [GPSCoord]
    private let distances: [Double]
    private let channelValues: [Double]
    private let colorScale: ChannelColorScale
    private let lapDistance: Double
    private let sectorSplits: Int
    @Binding private var cursorIndex: Int?

    public init(coords: [GPSCoord], distances: [Double], channelValues: [Double],
                colorScale: ChannelColorScale, lapDistance: Double, sectorSplits: Int,
                cursorIndex: Binding<Int?>) {
        self.coords = coords
        self.distances = distances
        self.channelValues = channelValues
        self.colorScale = colorScale
        self.lapDistance = lapDistance
        self.sectorSplits = sectorSplits
        _cursorIndex = cursorIndex
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let projection = projection(for: size)
                let projected = coords.map(projection.project)
                drawRacingLine(context, projected: projected)
                drawBoundaries(context, projected: projected)
                drawMarker(context, projected: projected)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let projected = coords.map(projection(for: geometry.size).project)
                    cursorIndex = TrackPath.nearestIndex(to: value.location, in: projected)
                }
            )
        }
        .accessibilityLabel("GPS track map")
    }

    private func projection(for size: CGSize) -> GeoProjection {
        GeoProjection.fit(to: coords, in: CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12))
    }

    /// Strokes each racing-line segment in its channel color.
    private func drawRacingLine(_ context: GraphicsContext, projected: [CGPoint]) {
        guard projected.count > 1 else { return }
        for i in 1..<projected.count {
            let start = projected[i - 1], end = projected[i]
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { continue }
            let value = channelValues.indices.contains(i) ? channelValues[i] : domainMidpoint
            var segment = Path()
            segment.move(to: start)
            segment.addLine(to: end)
            context.stroke(segment, with: .color(Color(colorScale.color(for: value))), lineWidth: 2.5)
        }
    }

    /// Dots each interior sector boundary (prominent) and mini-sector boundary
    /// (faint), placing them on the coordinate nearest each boundary distance.
    private func drawBoundaries(_ context: GraphicsContext, projected: [CGPoint]) {
        let model = SectorModel(lapDistance: lapDistance)
        boundaryDots(context, ranges: model.miniSectors(count: sectorSplits * 4),
                     projected: projected, radius: 2, color: .secondary.opacity(0.5))
        boundaryDots(context, ranges: model.boundaries(splits: sectorSplits),
                     projected: projected, radius: 4, color: .primary.opacity(0.7))
    }

    private func boundaryDots(_ context: GraphicsContext, ranges: [ClosedRange<Double>],
                              projected: [CGPoint], radius: CGFloat, color: Color) {
        // Skip the first range's start (distance 0 = the start/finish line).
        for range in ranges.dropFirst() {
            guard let index = hitTest(x: range.lowerBound, in: distances),
                  projected.indices.contains(index) else { continue }
            context.fill(dot(at: projected[index], radius: radius), with: .color(color))
        }
    }

    /// Draws the cursor marker on the track, when the shared cursor is set.
    private func drawMarker(_ context: GraphicsContext, projected: [CGPoint]) {
        guard let index = cursorIndex, let point = TrackPath.point(on: projected, at: index) else { return }
        context.fill(dot(at: point, radius: 5), with: .color(.red))
    }

    private func dot(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    private var domainMidpoint: Double {
        (colorScale.domain.lowerBound + colorScale.domain.upperBound) / 2
    }
}
