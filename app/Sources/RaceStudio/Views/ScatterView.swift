import SwiftUI
import RaceStudioCore

/// A channel-vs-channel XY scatter plot with a fitted trend line (issue 4.5):
/// one dot per `(x, y)` pair, plus the least-squares line when a `Fit` is given.
///
/// Thin: the pairing (`ScatterModel.points`) and the regression
/// (`LinearRegression.fit`) are computed in `RaceStudioCore`; this view only
/// maps the points to pixels with the 4.1 `LinearScale`/`plotDomain`, draws the
/// dots and the trend line, and labels the axes with the 4.1 `TickGenerator`.
public struct ScatterView: View {
    private let points: [CGPoint]
    private let fit: LinearRegression.Fit?
    private let pointColor: PlotColor

    // Domains derived once from the (immutable) points, not per frame.
    private let xDomain: ClosedRange<Double>
    private let yDomain: ClosedRange<Double>

    public init(points: [CGPoint], fit: LinearRegression.Fit? = nil,
                pointColor: PlotColor = PlotColor.palette[0]) {
        self.points = points
        self.fit = fit
        self.pointColor = pointColor
        self.xDomain = plotDomain(of: points.map { Double($0.x) })
        self.yDomain = plotDomain(of: points.map { Double($0.y) })
    }

    public var body: some View {
        Canvas { context, size in
            let width = max(size.width, 1)
            let height = max(size.height, 1)
            let xScale = LinearScale(domain: xDomain, range: 0...width)
            let yScale = LinearScale(domain: yDomain, range: 0...height)

            drawGrid(context, width: width, height: height, xScale: xScale, yScale: yScale)
            drawTrendLine(context, width: width, height: height, xScale: xScale, yScale: yScale)
            drawPoints(context, height: height, xScale: xScale, yScale: yScale)
        }
        .padding(8)
        .accessibilityLabel("Channel-vs-channel scatter plot")
    }

    private func drawPoints(_ context: GraphicsContext, height: CGFloat,
                            xScale: LinearScale, yScale: LinearScale) {
        let fill = GraphicsContext.Shading.color(Color(pointColor))
        let radius: CGFloat = 2
        for point in points {
            let px = xScale.map(Double(point.x))
            let py = height - yScale.map(Double(point.y)) // flip: value up → pixel up
            let dot = CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: fill)
        }
    }

    /// Strokes the regression line across the x-domain, when a fit is present.
    private func drawTrendLine(_ context: GraphicsContext, width: CGFloat, height: CGFloat,
                               xScale: LinearScale, yScale: LinearScale) {
        guard let fit else { return }
        let x0 = xDomain.lowerBound, x1 = xDomain.upperBound
        var line = Path()
        line.move(to: CGPoint(x: xScale.map(x0), y: height - yScale.map(fit.slope * x0 + fit.intercept)))
        line.addLine(to: CGPoint(x: xScale.map(x1), y: height - yScale.map(fit.slope * x1 + fit.intercept)))
        context.stroke(line, with: .color(.secondary), lineWidth: 1.5)
    }

    /// Faint gridlines with axis labels from `TickGenerator`.
    private func drawGrid(_ context: GraphicsContext, width: CGFloat, height: CGFloat,
                          xScale: LinearScale, yScale: LinearScale) {
        let grid = GraphicsContext.Shading.color(.secondary.opacity(0.25))
        for tick in TickGenerator.ticks(for: xDomain, targetCount: 6) {
            let px = xScale.map(tick)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: height))
            context.stroke(line, with: grid, lineWidth: 0.5)
            context.draw(AxisLabel.text(tick), at: CGPoint(x: px, y: height - 8))
        }
        for tick in TickGenerator.ticks(for: yDomain, targetCount: 5) {
            let py = height - yScale.map(tick)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: py))
            line.addLine(to: CGPoint(x: width, y: py))
            context.stroke(line, with: grid, lineWidth: 0.5)
            context.draw(AxisLabel.text(tick), at: CGPoint(x: 16, y: py))
        }
    }
}
