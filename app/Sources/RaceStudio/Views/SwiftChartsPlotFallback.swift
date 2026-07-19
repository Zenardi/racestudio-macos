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
    /// Optional per-series colour (keyed by trace name); when supplied the lines
    /// use it instead of Swift Charts' automatic palette, so a caller's own legend
    /// (e.g. the lap-overlay legend) matches the plotted lines. `nil` keeps the
    /// default palette (issue 8.7).
    var seriesColors: [String: Color]?
    /// The line width + per-sample dot size (issue 8.12); defaults to the Core's
    /// hairline-no-dots style so existing call sites are unchanged.
    var lineStyle: PlotLineStyle = PlotLineStyle()

    var body: some View {
        chart
            .chartXScale(domain: viewport.visible)
            .chartYScale(domain: valueDomain)
    }

    @ViewBuilder private var chart: some View {
        let base = Chart {
            ForEach(traces) { trace in
                let polyline = plotPolyline(trace: trace, mode: mode,
                                            visible: viewport.visible, columns: columns)
                ForEach(polyline) { point in
                    LineMark(
                        x: .value("x", point.x),
                        y: .value(trace.name, point.y),
                        series: .value("channel", trace.name)
                    )
                    .lineStyle(StrokeStyle(lineWidth: lineStyle.lineWidth))
                    .foregroundStyle(by: .value("channel", trace.name))
                    if lineStyle.showsDots {
                        PointMark(x: .value("x", point.x), y: .value(trace.name, point.y))
                            .symbolSize(lineStyle.dotSize * lineStyle.dotSize)
                            .foregroundStyle(by: .value("channel", trace.name))
                    }
                }
            }
        }
        if let seriesColors {
            base.chartForegroundStyleScale(domain: traces.map(\.name),
                                           range: traces.map { seriesColors[$0.name] ?? .accentColor })
        } else {
            base
        }
    }
}
