import CoreGraphics

/// Ordinary least-squares straight-line fit `y = slope·x + intercept` over a set
/// of points, plus the coefficient of determination R² (issue 4.5).
public enum LinearRegression {
    /// The fitted line and its goodness of fit.
    public struct Fit: Equatable, Sendable {
        /// The slope of the regression line.
        public let slope: Double
        /// The y-intercept of the regression line.
        public let intercept: Double
        /// The coefficient of determination in `0...1` (1 = a perfect fit).
        public let r2: Double

        public init(slope: Double, intercept: Double, r2: Double) {
            self.slope = slope
            self.intercept = intercept
            self.r2 = r2
        }
    }

    /// The least-squares fit of `points`, or `nil` when it is undefined: fewer
    /// than two (finite) points, or zero variance in x (a vertical line has no
    /// slope). Non-finite points are dropped first, so a caller need not
    /// pre-filter.
    ///
    /// When x varies but y is constant the fit is the exact horizontal line
    /// through the data, reported with `r2 == 1`.
    public static func fit(_ points: [CGPoint]) -> Fit? {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard finite.count >= 2 else { return nil }

        let count = Double(finite.count)
        var sumX = 0.0, sumY = 0.0
        for point in finite {
            sumX += Double(point.x)
            sumY += Double(point.y)
        }
        let meanX = sumX / count, meanY = sumY / count

        // A second pass for the deviations (subtracting the mean first is the
        // numerically stable form).
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for point in finite {
            let dx = Double(point.x) - meanX
            let dy = Double(point.y) - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil } // zero x-variance → no slope

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        // Sxy²/(Sxx·Syy); a flat y (Syy == 0) is fit perfectly by y = meanY.
        // Clamped to 0...1 because rounding can push a near-perfect fit a hair
        // past 1 (Cauchy–Schwarz holds only in exact arithmetic).
        let r2 = syy == 0 ? 1 : ((sxy * sxy) / (sxx * syy)).clamped(to: 0...1)
        return Fit(slope: slope, intercept: intercept, r2: r2)
    }
}
