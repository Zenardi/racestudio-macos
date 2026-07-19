import SwiftUI
import RaceStudioCore

/// Which render backend a ``TimeDistancePlotView`` uses (ADR 0003).
public enum PlotRenderKind: Sendable {
    /// GPU line strips — the primary path for dense laps.
    case metal
    /// Swift Charts — the correctness / low-density fallback.
    case swiftCharts
}

/// The reusable multi-channel time/distance line plot (issues 4.1, 8.12).
///
/// This SwiftUI view is deliberately **thin**: it owns the x-axis toggle, the
/// arrangement-mode / line-style / snap controls, zoom/pan gestures, the
/// tick/gridline overlay, and layout, then hands the trace drawing to either
/// ``MetalPlotRenderer`` or ``SwiftChartsPlotFallback``. Every numeric decision —
/// value↔pixel scales (`LinearScale`), nice ticks (`TickGenerator`), the zoom/pan
/// window (`PlotViewport`), the plot domains (`plotDomain`), the mode→graph
/// arrangement (`PlotArrangement`), the whole-lap snap (`snapToLapBoundaries`), and
/// the visible-window decimation (`plotPolyline`/`envelope`) — lives in
/// `RaceStudioCore`, so this file carries no geometry of its own.
///
/// Line width and per-sample dots (`PlotLineStyle`) render in the Swift Charts path;
/// the Metal path stays the dense hairline primary per ADR 0003.
public struct TimeDistancePlotView: View {
    private let traces: [ChannelTrace]
    private let renderer: PlotRenderKind
    /// Optional per-series colour (keyed by trace name) for the Swift Charts
    /// renderer, so a caller with its own legend can match the plotted lines
    /// (issue 8.7); `nil` keeps the default palette.
    private let seriesColors: [String: Color]?
    /// Lap-edge x-positions on the **time** basis (each lap's start plus the final
    /// end); when non-empty and snap is on, zoom/pan settle onto whole laps
    /// (issue 8.12). Empty disables snap.
    private let lapBoundaries: [Double]

    // Domains are derived from the (immutable) traces once, at init, so the
    // per-frame body does not re-scan every sample during a gesture.
    private let timeDomain: ClosedRange<Double>
    private let distanceDomain: ClosedRange<Double>
    private let valueDomain: ClosedRange<Double>
    /// Per-trace value domain (keyed by trace name) so a per-graph Y arrangement
    /// scales each band to only its own channels without re-scanning per frame.
    private let valueDomainByName: [String: ClosedRange<Double>]
    private let traceByName: [String: ChannelTrace]

    @State private var mode: XAxisMode
    @State private var arrangement: PlotArrangementMode = .overlapped
    @State private var lineWidth: Double = PlotLineStyle().lineWidth
    @State private var dotSize: Double = 0
    @State private var snapToLaps = false
    @State private var viewport: PlotViewport
    @State private var dragBase: PlotViewport?
    @State private var zoomBase: PlotViewport?

    public init(traces: [ChannelTrace], mode: XAxisMode = .distance, renderer: PlotRenderKind = .metal,
                seriesColors: [String: Color]? = nil, lapBoundaries: [Double] = []) {
        self.traces = traces
        self.renderer = renderer
        self.seriesColors = seriesColors
        self.lapBoundaries = lapBoundaries
        let timeDomain = plotDomain(of: traces.flatMap { $0.xValues(mode: .time) })
        let distanceDomain = plotDomain(of: traces.flatMap { $0.xValues(mode: .distance) })
        self.timeDomain = timeDomain
        self.distanceDomain = distanceDomain
        self.valueDomain = plotDomain(of: traces.flatMap { $0.samples.map(\.value) })
        self.valueDomainByName = Dictionary(
            traces.map { ($0.name, plotDomain(of: $0.samples.map(\.value))) },
            uniquingKeysWith: { first, _ in first })
        self.traceByName = Dictionary(traces.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        _mode = State(initialValue: mode)
        _viewport = State(initialValue: PlotViewport(bounds: mode == .time ? timeDomain : distanceDomain))
    }

    /// The full x-extent for the current axis mode.
    private var xDomain: ClosedRange<Double> { mode == .time ? timeDomain : distanceDomain }

    /// The current line/dot styling, built from the two sliders through the Core's
    /// clamping initializer.
    private var lineStyle: PlotLineStyle { PlotLineStyle(lineWidth: lineWidth, dotSize: dotSize) }

    /// Whether the whole-lap snap can act: enabled, on the time basis, with lap edges.
    private var snapActive: Bool { snapToLaps && mode == .time && !lapBoundaries.isEmpty }

    public var body: some View {
        VStack(spacing: 8) {
            controls
            GeometryReader { geometry in
                let columns = columnCount(for: geometry.size.width)
                let graphs = PlotArrangement.arrange(mode: arrangement, channels: traces.map(\.name)).graphs
                VStack(spacing: 6) {
                    ForEach(graphs) { graph in
                        band(graph, columns: columns)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
                .gesture(zoomGesture())
            }
        }
        .padding(8)
        // Reset the window whenever the x-extent changes — either the axis mode
        // toggled, or the parent handed the reusable view a different trace set.
        .onChange(of: xDomain) { newDomain in
            viewport = PlotViewport(bounds: newDomain)
        }
        // Settle onto whole laps the moment snap is switched on.
        .onChange(of: snapToLaps) { _ in viewport = snapped(viewport) }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Picker("X axis", selection: $mode) {
                    Text("Time").tag(XAxisMode.time)
                    Text("Distance").tag(XAxisMode.distance)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Picker("Layout", selection: $arrangement) {
                    ForEach(PlotArrangementMode.allCases) { layout in
                        Label(layout.title, systemImage: layout.systemImageName).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                if !lapBoundaries.isEmpty {
                    Toggle("Snap to laps", isOn: $snapToLaps)
                        .toggleStyle(.switch)
                        .fixedSize()
                        .disabled(mode != .time)
                        .help("Constrain zoom/pan to whole-lap boundaries")
                }
                Spacer()
            }
            HStack(spacing: 16) {
                slider("Line", value: $lineWidth,
                       range: PlotLineStyle.minLineWidth...PlotLineStyle.maxLineWidth)
                slider("Dots", value: $dotSize, range: 0...PlotLineStyle.maxDotSize)
                Spacer()
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Slider(value: value, in: range).frame(width: 120)
        }
    }

    // MARK: - Bands (one per arranged graph)

    /// One arranged graph rendered as a band: its member traces on the shared x
    /// window, scaled to a shared Y (overlapped) or its own per-graph Y.
    @ViewBuilder private func band(_ graph: PlotGraph, columns: Int) -> some View {
        let bandTraces = graph.channelNames.compactMap { traceByName[$0] }
        let domain = valueDomain(for: graph)
        plotBody(traces: bandTraces, valueDomain: domain, columns: columns)
            .overlay(AxisOverlay(visible: viewport.visible, valueDomain: domain))
    }

    /// The value domain for `graph`: the whole-plot domain when arrangement shares
    /// one Y axis (overlapped), else the union of only this graph's channels.
    private func valueDomain(for graph: PlotGraph) -> ClosedRange<Double> {
        guard arrangement != .overlapped else { return valueDomain }
        let members = graph.channelNames.compactMap { valueDomainByName[$0] }
        guard let first = members.first else { return valueDomain }
        let low = members.dropFirst().reduce(first.lowerBound) { min($0, $1.lowerBound) }
        let high = members.dropFirst().reduce(first.upperBound) { max($0, $1.upperBound) }
        return low <= high ? low...high : valueDomain
    }

    @ViewBuilder
    private func plotBody(traces: [ChannelTrace], valueDomain: ClosedRange<Double>, columns: Int) -> some View {
        switch renderer {
        case .metal:
            MetalPlotRenderer(traces: traces, mode: mode, viewport: viewport,
                              valueDomain: valueDomain, columns: columns)
        case .swiftCharts:
            SwiftChartsPlotFallback(traces: traces, mode: mode, viewport: viewport,
                                    valueDomain: valueDomain, columns: columns,
                                    seriesColors: seriesColors, lineStyle: lineStyle)
        }
    }

    /// A safe pixel-column count: guards the `Double → Int` conversion against a
    /// non-finite or absurd width (which would trap), and floors at 1.
    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(min(width, 100_000)))
    }

    // MARK: - Gestures (thin: they only feed PlotViewport math)

    /// Snaps `vp` to whole-lap boundaries when snap is active, else returns it
    /// unchanged — the sole gesture-side use of `snapToLapBoundaries`.
    private func snapped(_ vp: PlotViewport) -> PlotViewport {
        guard snapActive else { return vp }
        let visible = snapToLapBoundaries(vp.visible, boundaries: lapBoundaries)
        return PlotViewport(bounds: vp.bounds, visible: visible, minSpan: vp.minSpan)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragBase ?? viewport
                dragBase = base
                let fraction = width > 0 ? Double(value.translation.width / width) : 0
                viewport = base.pan(by: -fraction * base.span)
            }
            .onEnded { _ in
                dragBase = nil
                viewport = snapped(viewport)
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                let base = zoomBase ?? viewport
                zoomBase = base
                // Pinch-out (magnification > 1) zooms in → shrinks the span.
                let factor = magnification > 0 ? 1 / Double(magnification) : 1
                viewport = base.zoom(factor: factor, anchor: 0.5)
            }
            .onEnded { _ in
                zoomBase = nil
                viewport = snapped(viewport)
            }
    }
}

/// Nice-tick gridlines and axis labels drawn from `TickGenerator` + `LinearScale`
/// over the visible window. Purely presentational (no hit-testing); the numeric
/// tick/scale math is all in `RaceStudioCore`.
private struct AxisOverlay: View {
    let visible: ClosedRange<Double>
    let valueDomain: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let width = max(size.width, 1)
            let height = max(size.height, 1)
            let xScale = LinearScale(domain: visible, range: 0...width)
            let yScale = LinearScale(domain: valueDomain, range: 0...height)
            let grid = GraphicsContext.Shading.color(.secondary.opacity(0.25))

            for tick in TickGenerator.ticks(for: visible, targetCount: 6) {
                let px = xScale.map(tick)
                var line = Path()
                line.move(to: CGPoint(x: px, y: 0))
                line.addLine(to: CGPoint(x: px, y: height))
                context.stroke(line, with: grid, lineWidth: 0.5)
                context.draw(label(tick), at: CGPoint(x: px, y: height - 8))
            }
            for tick in TickGenerator.ticks(for: valueDomain, targetCount: 5) {
                let py = height - yScale.map(tick) // flip: value up → pixel up
                var line = Path()
                line.move(to: CGPoint(x: 0, y: py))
                line.addLine(to: CGPoint(x: width, y: py))
                context.stroke(line, with: grid, lineWidth: 0.5)
                context.draw(label(tick), at: CGPoint(x: 20, y: py))
            }
        }
        .allowsHitTesting(false)
    }

    private func label(_ value: Double) -> Text {
        Text(String(format: "%g", value)).font(.caption2).foregroundColor(.secondary)
    }
}
