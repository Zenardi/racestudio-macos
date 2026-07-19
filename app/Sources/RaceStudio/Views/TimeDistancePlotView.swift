import SwiftUI
import RaceStudioCore

/// Which render backend a ``TimeDistancePlotView`` uses (ADR 0003).
public enum PlotRenderKind: Sendable {
    /// GPU line strips — the primary path for dense laps.
    case metal
    /// Swift Charts — the correctness / low-density fallback.
    case swiftCharts
}

/// The reusable multi-channel time/distance line plot (issue 4.1).
///
/// This SwiftUI view is deliberately **thin**: it owns the x-axis toggle,
/// zoom/pan gestures, the tick/gridline overlay, and layout, then hands the
/// trace drawing to either ``MetalPlotRenderer`` or ``SwiftChartsPlotFallback``.
/// Every numeric decision — value↔pixel scales (`LinearScale`), nice ticks
/// (`TickGenerator`), the zoom/pan window (`PlotViewport`), the plot domains
/// (`plotDomain`), and the visible-window decimation (`plotPolyline`/`envelope`)
/// — lives in `RaceStudioCore`, so this file carries no geometry of its own.
public struct TimeDistancePlotView: View {
    private let traces: [ChannelTrace]
    private let renderer: PlotRenderKind
    /// Optional per-series colour (keyed by trace name) for the Swift Charts
    /// renderer, so a caller with its own legend can match the plotted lines
    /// (issue 8.7); `nil` keeps the default palette.
    private let seriesColors: [String: Color]?

    // Domains are derived from the (immutable) traces once, at init, so the
    // per-frame body does not re-scan every sample during a gesture.
    private let timeDomain: ClosedRange<Double>
    private let distanceDomain: ClosedRange<Double>
    private let valueDomain: ClosedRange<Double>

    @State private var mode: XAxisMode
    @State private var viewport: PlotViewport
    @State private var dragBase: PlotViewport?
    @State private var zoomBase: PlotViewport?

    public init(traces: [ChannelTrace], mode: XAxisMode = .distance, renderer: PlotRenderKind = .metal,
                seriesColors: [String: Color]? = nil) {
        self.traces = traces
        self.renderer = renderer
        self.seriesColors = seriesColors
        let timeDomain = plotDomain(of: traces.flatMap { $0.xValues(mode: .time) })
        let distanceDomain = plotDomain(of: traces.flatMap { $0.xValues(mode: .distance) })
        self.timeDomain = timeDomain
        self.distanceDomain = distanceDomain
        self.valueDomain = plotDomain(of: traces.flatMap { $0.samples.map(\.value) })
        _mode = State(initialValue: mode)
        _viewport = State(initialValue: PlotViewport(bounds: mode == .time ? timeDomain : distanceDomain))
    }

    /// The full x-extent for the current axis mode.
    private var xDomain: ClosedRange<Double> { mode == .time ? timeDomain : distanceDomain }

    public var body: some View {
        VStack(spacing: 8) {
            Picker("X axis", selection: $mode) {
                Text("Time").tag(XAxisMode.time)
                Text("Distance").tag(XAxisMode.distance)
            }
            .pickerStyle(.segmented)

            GeometryReader { geometry in
                let columns = columnCount(for: geometry.size.width)
                plotBody(columns: columns)
                    .overlay(AxisOverlay(visible: viewport.visible, valueDomain: valueDomain))
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
    }

    @ViewBuilder
    private func plotBody(columns: Int) -> some View {
        switch renderer {
        case .metal:
            MetalPlotRenderer(traces: traces, mode: mode, viewport: viewport,
                              valueDomain: valueDomain, columns: columns)
        case .swiftCharts:
            SwiftChartsPlotFallback(traces: traces, mode: mode, viewport: viewport,
                                    valueDomain: valueDomain, columns: columns, seriesColors: seriesColors)
        }
    }

    /// A safe pixel-column count: guards the `Double → Int` conversion against a
    /// non-finite or absurd width (which would trap), and floors at 1.
    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(min(width, 100_000)))
    }

    // MARK: - Gestures (thin: they only feed PlotViewport math)

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = dragBase ?? viewport
                dragBase = base
                let fraction = width > 0 ? Double(value.translation.width / width) : 0
                viewport = base.pan(by: -fraction * base.span)
            }
            .onEnded { _ in dragBase = nil }
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
            .onEnded { _ in zoomBase = nil }
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
