import SwiftUI
import Charts
import RaceStudioCore

/// The Swift Charts correctness / low-density fallback renderer (issue 4.1,
/// ADR 0003).
///
/// Draws each trace as a `LineMark` polyline built by `RaceStudioCore`'s
/// `plotPolyline(trace:mode:visible:columns:)` — the same visible-window,
/// `envelope`-decimated points the Metal path draws. Holds no numeric logic of
/// its own.
struct SwiftChartsPlotFallback: View {
    let traces: [ChannelTrace]
    let mode: XAxisMode
    let viewport: PlotViewport
    let valueDomain: ClosedRange<Double>
    let columns: Int

    var body: some View {
        Chart {
            ForEach(traces) { trace in
                let polyline = plotPolyline(trace: trace, mode: mode,
                                            visible: viewport.visible, columns: columns)
                ForEach(polyline) { point in
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
