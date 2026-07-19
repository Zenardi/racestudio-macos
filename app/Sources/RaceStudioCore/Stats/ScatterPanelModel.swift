import CoreGraphics

/// Assembles the reused `ScatterView`'s inputs from two channels (issue 8.9): the
/// paired `(x, y)` cloud — the friction-circle **G-G diagram** when the axes are
/// lateral vs longitudinal acceleration — and, optionally, the least-squares trend
/// line through it.
///
/// Pure: pairs via `ScatterModel.points` and fits via `LinearRegression.fit`, both
/// Core-tested; the view only maps the points to pixels and strokes the line. The
/// fit is `nil` when it is undefined (fewer than two points, or a vertical cloud)
/// or when the regression line is switched off.
public struct ScatterPanelModel: Sendable {

    /// The x-axis channel name (empty when unavailable).
    public let xChannel: String

    /// The y-axis channel name (empty when unavailable).
    public let yChannel: String

    /// The paired `(x, y)` cloud, index-aligned on the x-channel's basis.
    public let points: [CGPoint]

    /// The least-squares trend line, or `nil` when regression is off or undefined.
    public let fit: LinearRegression.Fit?

    /// - Parameters:
    ///   - xChannel/yChannel: the two channels' display names (for the axis labels).
    ///   - x/y: the two channels' series, paired index-for-index.
    ///   - window: an optional basis window restricting the cloud to a subset.
    ///   - regression: whether to fit the trend line (on by default).
    public init(xChannel: String, yChannel: String,
                x: ChannelSeries, y: ChannelSeries,
                window: ClosedRange<Double>? = nil, regression: Bool = true) {
        self.xChannel = xChannel
        self.yChannel = yChannel
        let points = ScatterModel.points(x: x, y: y, window: window)
        self.points = points
        self.fit = regression ? LinearRegression.fit(points) : nil
    }
}
