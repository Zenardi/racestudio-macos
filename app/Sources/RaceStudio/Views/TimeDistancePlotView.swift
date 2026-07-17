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
/// zoom/pan gestures, and layout, then hands the drawing to either
/// ``MetalPlotRenderer`` or ``SwiftChartsPlotFallback``. Every numeric decision —
/// value↔pixel scales (`LinearScale`), nice ticks (`TickGenerator`), the zoom/pan
/// window (`PlotViewport`), hit-testing and the min/max decimation (`envelope`) —
/// lives in `RaceStudioCore`, so this file carries no geometry of its own.
public struct TimeDistancePlotView: View {
    private let traces: [ChannelTrace]
    private let renderer: PlotRenderKind

    @State private var mode: XAxisMode
    @State private var viewport: PlotViewport
    @State private var gestureBase: PlotViewport?

    public init(traces: [ChannelTrace], mode: XAxisMode = .distance, renderer: PlotRenderKind = .metal) {
        self.traces = traces
        self.renderer = renderer
        _mode = State(initialValue: mode)
        _viewport = State(initialValue: PlotViewport(bounds: Self.xBounds(of: traces, mode: mode)))
    }

    public var body: some View {
        VStack(spacing: 8) {
            Picker("X axis", selection: $mode) {
                Text("Time").tag(XAxisMode.time)
                Text("Distance").tag(XAxisMode.distance)
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { newMode in
                viewport = PlotViewport(bounds: Self.xBounds(of: traces, mode: newMode))
            }

            GeometryReader { geometry in
                let columns = max(1, Int(geometry.size.width))
                plotBody(columns: columns)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: geometry.size.width))
                    .gesture(zoomGesture())
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func plotBody(columns: Int) -> some View {
        switch renderer {
        case .metal:
            MetalPlotRenderer(traces: traces, mode: mode, viewport: viewport,
                              valueDomain: valueDomain, columns: columns)
        case .swiftCharts:
            SwiftChartsPlotFallback(traces: traces, mode: mode, viewport: viewport,
                                    valueDomain: valueDomain, columns: columns)
        }
    }

    // MARK: - Gestures (thin: they only feed PlotViewport math)

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = gestureBase ?? viewport
                gestureBase = base
                let fraction = width > 0 ? Double(value.translation.width / width) : 0
                viewport = base.pan(by: -fraction * base.span)
            }
            .onEnded { _ in gestureBase = nil }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                let base = gestureBase ?? viewport
                gestureBase = base
                // Pinch-out (magnification > 1) zooms in → shrinks the span.
                let factor = magnification > 0 ? 1 / Double(magnification) : 1
                viewport = base.zoom(factor: factor, anchor: 0.5)
            }
            .onEnded { _ in gestureBase = nil }
    }

    // MARK: - Domains derived from the traces

    private var valueDomain: ClosedRange<Double> {
        let values = traces.flatMap { $0.samples.map(\.value) }
        guard let low = values.min(), let high = values.max(), low < high else {
            return (values.first ?? 0)...((values.first ?? 0) + 1)
        }
        return low...high
    }

    private static func xBounds(of traces: [ChannelTrace], mode: XAxisMode) -> ClosedRange<Double> {
        let xs = traces.flatMap { $0.xValues(mode: mode) }
        guard let low = xs.min(), let high = xs.max(), low < high else {
            return 0...1
        }
        return low...high
    }
}

/// A single point of a plotted polyline in domain coordinates.
struct PlotPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
}

/// Builds the polyline a renderer draws for `trace` on the `mode` x-basis.
///
/// When the trace is denser than `columns` pixels it is decimated to per-column
/// min/max pairs via `RaceStudioCore.envelope` (emitted in sample order so the
/// line stays monotonic in x); otherwise the raw samples are returned. Shared by
/// both render paths so they draw the identical visible envelope (ADR 0003).
func plotPolyline(trace: ChannelTrace, mode: XAxisMode, columns: Int) -> [PlotPoint] {
    let xs = trace.xValues(mode: mode)
    let values = trace.samples.map(\.value)
    guard columns > 0, values.count > columns else {
        return xs.indices.map { PlotPoint(id: $0, x: xs[$0], y: values[$0]) }
    }
    var points: [PlotPoint] = []
    points.reserveCapacity(columns * 2)
    var id = 0
    for extent in envelope(values: values, columns: columns) {
        let lower = min(extent.minIndex, extent.maxIndex)
        let upper = max(extent.minIndex, extent.maxIndex)
        points.append(PlotPoint(id: id, x: xs[lower], y: values[lower]))
        id += 1
        if upper != lower {
            points.append(PlotPoint(id: id, x: xs[upper], y: values[upper]))
            id += 1
        }
    }
    return points
}
