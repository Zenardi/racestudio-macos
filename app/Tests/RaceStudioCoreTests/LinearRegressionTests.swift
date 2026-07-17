import Testing
import CoreGraphics
@testable import RaceStudioCore

/// Tests for `LinearRegression` (issue 4.5) — ordinary least-squares fit.
@Suite struct LinearRegressionTests {

    @Test func test_regression_matches_golden() throws {
        // Hand-computed least-squares fit for these five points:
        //   x = [1,2,3,4,5], y = [2,4,5,4,5];  meanX = 3, meanY = 4
        //   Sxy = 6, Sxx = 10, Syy = 6
        //   slope = Sxy/Sxx = 0.6 ; intercept = meanY − slope·meanX = 2.2
        //   R² = Sxy² / (Sxx·Syy) = 36 / 60 = 0.6
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 4), CGPoint(x: 3, y: 5),
                      CGPoint(x: 4, y: 4), CGPoint(x: 5, y: 5)]
        let fit = try #require(LinearRegression.fit(points))
        #expect(abs(fit.slope - 0.6) < 1e-9)
        #expect(abs(fit.intercept - 2.2) < 1e-9)
        #expect(abs(fit.r2 - 0.6) < 1e-9)
    }

    @Test func test_regression_nil_for_fewer_than_two_points() {
        #expect(LinearRegression.fit([]) == nil)
        #expect(LinearRegression.fit([CGPoint(x: 1, y: 2)]) == nil)
    }

    @Test func test_regression_nil_for_zero_x_variance() {
        // All points share an x → a vertical line has no least-squares slope.
        let points = [CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 5), CGPoint(x: 3, y: 9)]
        #expect(LinearRegression.fit(points) == nil)
    }

    @Test func test_regression_perfect_line_has_unit_r2() throws {
        let points = (0...10).map { CGPoint(x: CGFloat($0), y: CGFloat(2 * $0 + 1)) }
        let fit = try #require(LinearRegression.fit(points))
        #expect(abs(fit.slope - 2) < 1e-9)
        #expect(abs(fit.intercept - 1) < 1e-9)
        #expect(abs(fit.r2 - 1) < 1e-9)
    }

    @Test func test_regression_ignores_nonfinite_points() {
        // NaN / ∞ coordinates are dropped before fitting; the two finite points
        // (0,0) and (2,4) still yield slope 2.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 5),
                      CGPoint(x: 2, y: 4), CGPoint(x: 3, y: CGFloat.infinity)]
        #expect(LinearRegression.fit(points)?.slope == 2)
    }
}
