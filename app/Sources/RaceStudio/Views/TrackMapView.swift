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
    /// Indices where a separately drawn run (one per selected lap) begins; no
    /// segment is stroked *into* one, so separate laps are never joined.
    private let runStarts: Set<Int>
    /// The map imagery drawn under the racing line, or ``TrackMapBackdrop/none``.
    private let backdrop: TrackMapBackdrop
    @Binding private var cursorIndex: Int?

    /// Mini-sectors drawn per sector (they nest within the sector boundaries).
    private static let miniSectorsPerSector = 4

    public init(coords: [GPSCoord], distances: [Double], channelValues: [Double],
                colorScale: ChannelColorScale, lapDistance: Double, sectorSplits: Int,
                runStarts: [Int] = [0],
                backdrop: TrackMapBackdrop = .none,
                cursorIndex: Binding<Int?>) {
        self.coords = coords
        self.distances = distances
        self.channelValues = channelValues
        self.colorScale = colorScale
        self.lapDistance = lapDistance
        self.sectorSplits = sectorSplits
        self.runStarts = Set(runStarts)
        self.backdrop = backdrop
        _cursorIndex = cursorIndex
    }

    public var body: some View {
        GeometryReader { geometry in
            // Fit + project once per render; the Canvas and the drag both reuse it.
            let fitted = projection(for: geometry.size)
            let projected = coords.map(fitted.project)
            Canvas { context, _ in
                drawRacingLine(context, projected: projected)
                drawBoundaries(context, projected: projected)
                drawMarker(context, projected: projected)
            }
            // Imagery goes *behind* the Canvas, covering exactly the ground the
            // projection maps onto this view — see `TrackMapBackdropView`.
            .background(mapBackdrop(size: geometry.size, projection: fitted))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    cursorIndex = TrackPath.nearestIndex(to: value.location, in: projected)
                }
            )
        }
        .accessibilityLabel(L10n.string(.chartTrackMap))
    }

    /// The map under the line, or nothing when no imagery is wanted or the session
    /// has no extent to frame.
    @ViewBuilder
    private func mapBackdrop(size: CGSize, projection: GeoProjection) -> some View {
        if backdrop != .none, let region = GeoRegion.covering(projection, size: size) {
            TrackMapBackdropView(region: region, style: backdrop)
        }
    }

    /// The fraction of each axis's extremes excluded when framing the racing line.
    ///
    /// Taking the plain min/max framed one 207 m circuit across 924 m, leaving the
    /// line a squiggle in the middle and the map backdrop zoomed uselessly far out.
    /// In that session 95% of fixes sat within 122 m of the circuit and then a tight
    /// cluster of 575 (3%) sat ~700 m away — a coherent excursion, not scatter. 5%
    /// rejects it and frames the track at 215 m, while costing a clean trace 1.4%:
    ///
    ///     trim   real trace   clean circuit
    ///     0.00      924 m         209 m
    ///     0.04      257 m         207 m
    ///     0.05      215 m         206 m
    ///     0.08      198 m         202 m
    ///
    /// Trimmed fixes are still *drawn* — they are only excluded from the bounds — so
    /// nothing is hidden, it simply falls outside the pane.
    private static let framingTrim = 0.05

    private func projection(for size: CGSize) -> GeoProjection {
        // Clamp the inset to half the size so a small pane never yields a null rect.
        let inset = CGRect(origin: .zero, size: size)
            .insetBy(dx: min(12, size.width / 2), dy: min(12, size.height / 2))
        return GeoProjection.fit(to: coords, in: inset, trimmingFraction: Self.framingTrim)
    }

    /// Strokes each racing-line segment in the color of its start sample; a
    /// segment with no aligned channel value is drawn neutral.
    private func drawRacingLine(_ context: GraphicsContext, projected: [CGPoint]) {
        guard projected.count > 1 else { return }
        for i in 1..<projected.count where !runStarts.contains(i) {
            let start = projected[i - 1], end = projected[i]
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { continue }
            let color = channelValues.indices.contains(i - 1)
                ? Color(colorScale.color(for: channelValues[i - 1]))
                : Color.gray
            var segment = Path()
            segment.move(to: start)
            segment.addLine(to: end)
            // Over satellite imagery the channel colours lose contrast against grass
            // and tarmac, so the line gets a dark casing — omitted on the plain
            // background, where it would only muddy the colour.
            if backdrop != .none {
                context.stroke(segment, with: .color(.black.opacity(0.55)), lineWidth: 5)
            }
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
