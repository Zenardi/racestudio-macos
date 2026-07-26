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

    /// Mini-sectors drawn per sector (they nest within the sector boundaries).
    private static let miniSectorsPerSector = 4

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
            // Fit + project once per render; the Canvas and the drag both reuse it.
            let projected = coords.map(projection(for: geometry.size).project)
            Canvas { context, _ in
                drawRacingLine(context, projected: projected)
                drawBoundaries(context, projected: projected)
                drawMarker(context, projected: projected)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    cursorIndex = TrackPath.nearestIndex(to: value.location, in: projected)
                }
            )
        }
        .accessibilityLabel(L10n.string(.chartTrackMap))
    }

    private func projection(for size: CGSize) -> GeoProjection {
        // Clamp the inset to half the size so a small pane never yields a null rect.
        let inset = CGRect(origin: .zero, size: size)
            .insetBy(dx: min(12, size.width / 2), dy: min(12, size.height / 2))
        return GeoProjection.fit(to: coords, in: inset)
    }

    /// Strokes each racing-line segment in the color of its start sample; a
    /// segment with no aligned channel value is drawn neutral.
    private func drawRacingLine(_ context: GraphicsContext, projected: [CGPoint]) {
        guard projected.count > 1 else { return }
        for i in 1..<projected.count {
            let start = projected[i - 1], end = projected[i]
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { continue }
            let color = channelValues.indices.contains(i - 1)
                ? Color(colorScale.color(for: channelValues[i - 1]))
                : Color.gray
            var segment = Path()
            segment.move(to: start)
            segment.addLine(to: end)
            context.stroke(segment, with: .color(color), lineWidth: 2.5)
        }
    }

    /// Dots each interior sector boundary (prominent) and mini-sector boundary
    /// (faint), placing them on the coordinate nearest each boundary distance.
    private func drawBoundaries(_ context: GraphicsContext, projected: [CGPoint]) {
        let model = SectorModel(lapDistance: lapDistance)
        boundaryDots(context, ranges: model.miniSectors(count: sectorSplits * Self.miniSectorsPerSector),
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
}
