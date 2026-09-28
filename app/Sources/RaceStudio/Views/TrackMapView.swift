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
///
/// Zoom and pan (the buttons, a trackpad pinch, and ⌥-drag) are a
/// `RaceStudioCore.MapViewport` applied on top of the automatic fit; a plain click
/// or drag still moves the cursor.
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

    /// The user's zoom / pan on top of the fit.
    @State private var viewport = MapViewport()
    /// The viewport when the current pinch or ⌥-drag began; each gesture applies
    /// its whole translation / magnification to this, not incrementally.
    @State private var gestureBase: MapViewport?
    /// The closest the map imagery will show, in pixels per degree of latitude —
    /// learned from what MapKit actually displays, `nil` until it has refused a
    /// region. MapKit will not zoom past ~0.54 m/pt on satellite imagery and
    /// silently shows a wider region instead, which drew a small circuit at about
    /// twice the size of the ground under it. The line is drawn at this scale.
    @State private var imageryScaleLimit: Double?

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
            let size = geometry.size
            // Fit, apply the user's zoom/pan, cap at what the imagery can show —
            // once per render; the Canvas, the drag and the backdrop all share it.
            let requested = viewport.apply(to: projection(for: size), in: size)
            let drawn = drawnProjection(requested, size: size)
            let projected = coords.map(drawn.project)
            Canvas { context, _ in
                drawRacingLine(context, projected: projected)
                drawBoundaries(context, projected: projected)
                drawMarker(context, projected: projected)
            }
            // Imagery goes *behind* the Canvas, covering exactly the ground the
            // projection maps onto this view — see `TrackMapBackdropView`.
            .background(mapBackdrop(size: size, projection: drawn, requested: requested))
            .contentShape(Rectangle())
            .gesture(pointerGesture(projected: projected, size: size))
            .simultaneousGesture(pinchGesture(size: size))
            .overlay(alignment: .bottomTrailing) {
                TrackMapControls(viewport: $viewport, size: size,
                                 atImageryLimit: isAtImageryLimit(requested))
                    .padding(8)
            }
            .clipped()
        }
        .accessibilityLabel(L10n.string(.chartTrackMap))
        .onChange(of: backdrop) { _ in imageryScaleLimit = nil }
    }

    /// The projection the line is drawn with: the requested one, capped at the
    /// imagery's limit while imagery is shown.
    private func drawnProjection(_ requested: GeoProjection, size: CGSize) -> GeoProjection {
        guard backdrop != .none, let limit = imageryScaleLimit else { return requested }
        return requested.limited(toScale: limit, about: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// Whether zooming in would only be refused by the imagery.
    private func isAtImageryLimit(_ requested: GeoProjection) -> Bool {
        guard backdrop != .none, let limit = imageryScaleLimit else { return false }
        return requested.scale >= limit * 0.999
    }

    /// A plain click / drag moves the cursor to the nearest fix; ⌥-drag pans.
    private func pointerGesture(projected: [CGPoint], size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if NSEvent.modifierFlags.contains(.option) {
                    var next = gestureBase ?? viewport
                    gestureBase = next
                    next.pan(by: value.translation, in: size)
                    viewport = next
                } else {
                    gestureBase = nil
                    cursorIndex = TrackPath.nearestIndex(to: value.location, in: projected)
                }
            }
            .onEnded { _ in gestureBase = nil }
    }

    /// Trackpad pinch zooms about the view centre.
    private func pinchGesture(size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                var next = gestureBase ?? viewport
                gestureBase = next
                next.zoom(by: Double(magnification), anchor: CGPoint(x: size.width / 2, y: size.height / 2),
                          in: size)
                viewport = next
            }
            .onEnded { _ in gestureBase = nil }
    }

    /// The map under the line, or nothing when no imagery is wanted or the session
    /// has no extent to frame.
    @ViewBuilder
    private func mapBackdrop(size: CGSize, projection: GeoProjection,
                             requested: GeoProjection) -> some View {
        if backdrop != .none, let region = GeoRegion.covering(projection, size: size) {
            TrackMapBackdropView(region: region, style: backdrop) { shown in
                imageryShowed(shown, size: size, requested: requested)
            }
        }
    }

    /// MapKit reported the region it really shows. Wider than asked means it hit
    /// its zoom limit: remember the limit so the line is drawn at the imagery's
    /// scale, and pull the zoom back so the buttons stay honest.
    private func imageryShowed(_ region: GeoRegion, size: CGSize, requested: GeoProjection) {
        guard let shown = region.zoomLimit(forRequest: requested, in: size) else { return }
        imageryScaleLimit = shown
        viewport.limitZoom(to: viewport.zoom * shown / requested.scale)
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
    /// nothing is hidden, it simply falls outside the pane. An axis is only trimmed
    /// when it actually has outliers (`GeoProjection.outlierExtentRatio`): a clean
    /// real lap lost 8–10% per axis to the trim, clipping its hairpins.
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
