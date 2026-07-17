import SwiftUI
import Charts
import RaceStudioCore

/// The Swift Charts correctness / low-density fallback renderer (issue 4.1,
/// ADR 0003).
///
/// Draws each trace as a `LineMark` polyline built by ``plotPolyline(trace:mode:columns:)``
/// — the same `RaceStudioCore.envelope`-decimated points the Metal path draws —
/// clipped to the visible ``PlotViewport``. Holds no numeric logic of its own.
struct SwiftChartsPlotFallback: View {
    let traces: [ChannelTrace]
    let mode: XAxisMode
    let viewport: PlotViewport
    let valueDomain: ClosedRange<Double>
    let columns: Int

    var body: some View {
        Chart {
            ForEach(traces) { trace in
                ForEach(plotPolyline(trace: trace, mode: mode, columns: columns)) { point in
                    LineMark(
                        x: .value("x", point.x),
                        y: .value(trace.name, point.y),
                        series: .value("channel", trace.name)
                    )
                    .foregroundStyle(by: .value("channel", trace.name))
                }
            }
        }
        .chartXScale(domain: viewport.visible)
        .chartYScale(domain: valueDomain)
    }
}
