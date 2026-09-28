import SwiftUI
import RaceStudioCore

/// The GPS track map (issue 4.3): the racing line coloured by lap or by a channel,
/// sector and mini-sector boundary marks, and a position marker per selected lap.
///
/// Thin: every geometric decision — the `GeoProjection` fit, the `TrackPath`
/// polyline and nearest-point lookup, the `ChannelColorScale`, and the
/// `SectorModel` boundaries — is computed in `RaceStudioCore`. This view only
/// strokes the resulting path and dots into a `Canvas` and turns a click into a
/// cursor index (the shared 4.7 cursor supplies/consumes `cursorIndex`).
///
/// Zoom and pan — the mouse wheel (about the pointer), a middle-button drag, a
/// trackpad pinch, ⌥-drag, and the buttons — are a `RaceStudioCore.MapViewport`
/// applied on top of the automatic fit; a plain click or drag still moves the cursor.
public struct TrackMapView: View {
    private let coords: [GPSCoord]
    private let distances: [Double]
    private let channelValues: [Double]
    private let colorScale: ChannelColorScale
    private let lapDistance: Double
    private let sectorSplits: Int
    /// Indices where a separately drawn run (one per selected lap) begins; no
    /// segment is stroked *into* one, so separate laps are never joined.
    private let runStarts: [Int]
    /// Each run's position in the lap selection — its colour (parallel to `runStarts`).
    private let runSlots: [Int]
    /// Each run's lap number, for the legend (parallel to `runStarts`).
    private let runLapNumbers: [Int?]
    /// `true` to draw each run in its lap's colour instead of the channel gradient.
    private let colorsByLap: Bool
    /// One position marker per selected lap (see `TrackMapModel.markers(atTime:)`).
    private let markers: [TrackMapMarker]
    /// The map imagery drawn under the racing line, or ``TrackMapBackdrop/none``.
    private let backdrop: TrackMapBackdrop
    @Binding private var cursorIndex: Int?

    /// The user's zoom / pan on top of the fit.
    @State private var viewport = MapViewport()
    /// The viewport when the current ⌥-drag began; the drag applies its whole
    /// translation to this, not incrementally.
    @State private var gestureBase: MapViewport?
    @StateObject private var imagery = TrackMapImageryLoader()

    /// Mini-sectors drawn per sector (they nest within the sector boundaries).
    private static let miniSectorsPerSector = 4

    public init(coords: [GPSCoord], distances: [Double], channelValues: [Double],
                colorScale: ChannelColorScale, lapDistance: Double, sectorSplits: Int,
                runStarts: [Int] = [0], runSlots: [Int] = [0], runLapNumbers: [Int?] = [nil],
                colorsByLap: Bool = false, markers: [TrackMapMarker] = [],
                backdrop: TrackMapBackdrop = .none,
                cursorIndex: Binding<Int?>) {
        self.coords = coords
        self.distances = distances
        self.channelValues = channelValues
        self.colorScale = colorScale
        self.lapDistance = lapDistance
        self.sectorSplits = sectorSplits
        self.runStarts = runStarts
        self.runSlots = runSlots
        self.runLapNumbers = runLapNumbers
        self.colorsByLap = colorsByLap
        self.markers = markers
        self.backdrop = backdrop
        _cursorIndex = cursorIndex
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Fit, then apply the user's zoom/pan — once per render; the Canvas, the
            // drag and the imagery all share it.
            let projection = viewport.apply(to: fittedProjection(for: size), in: size)
            let projected = coords.map(projection.project)
            Canvas { context, _ in
                drawRacingLine(context, projected: projected)
                drawBoundaries(context, projected: projected)
                drawMarkers(context, projected: projected)
            }
            .background(imageryLayers(projection: projection, size: size))
            .background(MapPointerInput(
                onZoom: { factor, anchor in viewport.zoom(by: factor, anchor: anchor, in: size) },
                onPan: { translation in viewport.pan(by: translation, in: size) }))
            .contentShape(Rectangle())
            .gesture(pointerGesture(projected: projected, size: size))
            .overlay(alignment: .topLeading) { legend.padding(8) }
            .overlay(alignment: .bottomTrailing) {
                TrackMapControls(viewport: $viewport, size: size).padding(8)
            }
            .clipped()
        }
        .accessibilityLabel(L10n.string(.chartTrackMap))
        .onAppear(perform: loadImagery)
        .onChange(of: coords) { _ in loadImagery() }
        .onChange(of: backdrop) { _ in loadImagery() }
    }

    /// Fetch imagery around the ground the map frames (or drop it for no map).
    private func loadImagery() {
        imagery.load(framing: GeoProjection.framedRegion(of: coords, trimmingFraction: Self.framingTrim),
                     style: backdrop)
    }

    /// The snapshots, each scaled and placed so its ground lies under the line.
    private func imageryLayers(projection: GeoProjection, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if backdrop != .none {
                ForEach(Array(imagery.layers.enumerated()), id: \.offset) { _, layer in
                    if let frame = layer.tile.frame(in: projection) {
                        Image(nsImage: layer.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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

    /// Which colour is which lap, when more than one is drawn.
    @ViewBuilder private var legend: some View {
        let entries = legendEntries
        if entries.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.slot) { entry in
                    HStack(spacing: 4) {
                        Circle().fill(Color(PlotColor.selectionColor(at: entry.slot))).frame(width: 8, height: 8)
                        Text(entry.number.map { "Lap \($0)" } ?? "Lap")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
    }

    private var legendEntries: [(slot: Int, number: Int?)] {
        zip(runSlots, runLapNumbers).map { (slot: $0, number: $1) }.sorted { $0.slot < $1.slot }
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

    private func fittedProjection(for size: CGSize) -> GeoProjection {
        // Clamp the inset to half the size so a small pane never yields a null rect.
        let inset = CGRect(origin: .zero, size: size)
            .insetBy(dx: min(12, size.width / 2), dy: min(12, size.height / 2))
        return GeoProjection.fit(to: coords, in: inset, trimmingFraction: Self.framingTrim)
    }

    /// Strokes each lap's run — whole, in its lap's colour, or segment by segment
    /// in the colour of each segment's start sample on the channel gradient
    /// (neutral with no aligned value). Runs draw in time order, so where two laps
    /// share a line the later one is on top.
    private func drawRacingLine(_ context: GraphicsContext, projected: [CGPoint]) {
        for run in runStarts.indices {
            let start = runStarts[run]
            let end = run + 1 < runStarts.count ? runStarts[run + 1] : projected.count
            guard end - start > 1, end <= projected.count else { continue }
            let points = projected[start..<end]
            // Over map imagery the colours lose contrast against grass and tarmac,
            // so each run gets a dark casing, stroked as one path — per segment,
            // each casing would cut a dark notch into the joint before it. Omitted
            // on the plain background, where it would only muddy the colour.
            if backdrop != .none {
                context.stroke(polyline(points), with: .color(.black.opacity(0.55)), style: Self.casingStyle)
            }
            if colorsByLap, runSlots.indices.contains(run) {
                context.stroke(polyline(points), with: .color(Color(PlotColor.selectionColor(at: runSlots[run]))),
                               style: Self.lineStyle)
                continue
            }
            for i in (start + 1)..<end {
                let color = channelValues.indices.contains(i - 1)
                    ? Color(colorScale.color(for: channelValues[i - 1])) : Color.gray
                context.stroke(polyline(projected[(i - 1)...i]), with: .color(color), style: Self.lineStyle)
            }
        }
    }

    private static let lineStyle = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
    private static let casingStyle = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

    /// The finite points joined in order; a non-finite point (a dropped fix) breaks
    /// the line rather than drawing it to infinity.
    private func polyline(_ points: ArraySlice<CGPoint>) -> Path {
        var path = Path()
        var drawing = false
        for point in points {
            guard point.x.isFinite, point.y.isFinite else { drawing = false; continue }
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
        return path
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

    /// Draws each lap's position marker, the cursor's own lap last (on top) and
    /// largest. A marker in its lap's colour, ringed so it reads over any line
    /// colour or imagery; a lap that had already finished gets a white centre.
    private func drawMarkers(_ context: GraphicsContext, projected: [CGPoint]) {
        for marker in markers.sorted(by: { !$0.isCursorLap && $1.isCursorLap }) {
            guard let point = TrackPath.point(on: projected, at: marker.index) else { continue }
            let radius: CGFloat = marker.isCursorLap ? 7 : 5.5
            let color = marker.slot.map { Color(PlotColor.selectionColor(at: $0)) } ?? .red
            context.fill(dot(at: point, radius: radius + 2), with: .color(.black.opacity(0.6)))
            context.fill(dot(at: point, radius: radius + 1), with: .color(.white))
            context.fill(dot(at: point, radius: radius), with: .color(color))
            if marker.isBeyondLap {
                context.fill(dot(at: point, radius: radius * 0.45), with: .color(.white))
            }
        }
    }

    private func dot(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}
