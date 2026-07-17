import CoreGraphics

/// Pairs two channels sample-by-sample into `(x, y)` points for an XY scatter
/// plot (issue 4.5).
public struct ScatterModel {
    /// The `(x.value, y.value)` points formed by pairing the two channels index
    /// for index on their common basis.
    ///
    /// A pair is kept only when both channel values are finite (a `NaN`/missing
    /// sample in either channel drops the pair). When `window` is given, only
    /// samples whose basis (the x-channel's `xs`) falls inside it are paired —
    /// the caller passes the active cursor/selection window to restrict the plot
    /// to that subset. The shorter series bounds the pairing.
    public static func points(x: ChannelSeries,
                              y: ChannelSeries,
                              window: ClosedRange<Double>? = nil) -> [CGPoint] {
        let count = min(x.values.count, y.values.count)
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            if let window {
                let basis = x.xs[index]
                guard basis.isFinite, window.contains(basis) else { continue }
            }
            let xValue = x.values[index]
            let yValue = y.values[index]
            guard xValue.isFinite, yValue.isFinite else { continue }
            points.append(CGPoint(x: xValue, y: yValue))
        }
        return points
    }
}
