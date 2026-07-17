import SwiftUI
import RaceStudioCore

/// A channel-distribution histogram (issue 4.5): one bar per `Bin`, its height
/// proportional to the bin's count.
///
/// Thin: the binning (`Histogram.compute`) is done in `RaceStudioCore`; this
/// view only maps the resulting bins to pixels with the 4.1 `LinearScale` and
/// draws the bars and 4.1 `TickGenerator` gridlines. It carries no math of its
/// own.
public struct HistogramView: View {
    private let bins: [Bin]
    private let barColor: PlotColor

    public init(bins: [Bin], barColor: PlotColor = PlotColor.palette[0]) {
        self.bins = bins
        self.barColor = barColor
    }

    public var body: some View {
        Canvas { context, size in
            guard let first = bins.first, let last = bins.last,
                  let maxCount = bins.map(\.count).max(), maxCount > 0 else { return }
            let xScale = LinearScale(domain: first.lower...last.upper, range: 0...max(size.width, 1))
            let yScale = LinearScale(domain: 0...Double(maxCount), range: 0...max(size.height, 1))

            drawGrid(context, size: size, xScale: xScale, yScale: yScale)
            drawBars(context, size: size, xScale: xScale, yScale: yScale)
        }
        .padding(8)
        .accessibilityLabel("Channel distribution histogram")
    }

    /// Fills each bin as a bottom-anchored bar spanning `[lower, upper)` in x and
    /// rising to its count in y.
    private func drawBars(_ context: GraphicsContext, size: CGSize,
                          xScale: LinearScale, yScale: LinearScale) {
        let fill = GraphicsContext.Shading.color(Color(barColor))
        for bin in bins {
            let left = xScale.map(bin.lower)
            let right = xScale.map(bin.upper)
            let barHeight = yScale.map(Double(bin.count))
            // Inset by a hairline so adjacent bars read as separate columns.
            let rect = CGRect(x: left + 0.5, y: size.height - barHeight,
                              width: max(right - left - 1, 0), height: barHeight)
            context.fill(Path(rect), with: fill)
        }
    }

    /// Faint count gridlines with x/y labels, from `TickGenerator` (the domains
    /// come from the scales, so no extra parameters are needed).
    private func drawGrid(_ context: GraphicsContext, size: CGSize,
                          xScale: LinearScale, yScale: LinearScale) {
        let grid = GraphicsContext.Shading.color(.secondary.opacity(0.25))
        for tick in TickGenerator.ticks(for: yScale.domain, targetCount: 5) {
            let py = size.height - yScale.map(tick)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: py))
            line.addLine(to: CGPoint(x: size.width, y: py))
            context.stroke(line, with: grid, lineWidth: 0.5)
            context.draw(label(tick), at: CGPoint(x: 12, y: py))
        }
        for tick in TickGenerator.ticks(for: xScale.domain, targetCount: 6) {
            context.draw(label(tick), at: CGPoint(x: xScale.map(tick), y: size.height - 8))
        }
    }

    private func label(_ value: Double) -> Text {
        Text(String(format: "%g", value)).font(.caption2).foregroundColor(.secondary)
    }
}
