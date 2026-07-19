import Testing
import Foundation
import CoreGraphics
@testable import RaceStudioCore

/// Tests for `ScatterPanelModel` (issue 8.9): the pure feed adapter that pairs two
/// channels into the reused `ScatterView`'s `(x, y)` cloud — the friction-circle
/// **G-G diagram** when the axes are lateral vs longitudinal acceleration — and
/// optionally fits the least-squares trend line. Covered without SwiftUI or the FFI.
@Suite struct ScatterPanelModelTests {

    private func series(_ values: [Double], xs: [Double]? = nil) -> ChannelSeries {
        ChannelSeries(xs: xs ?? values.indices.map(Double.init), values: values)
    }

    // MARK: - Pairing (criterion 2: the channel-vs-channel cloud)

    @Test func test_points_pair_the_two_channels_by_index() {
        let model = ScatterPanelModel(xChannel: "AccLat", yChannel: "AccLong",
                                      x: series([0, 1, 2]), y: series([0, 2, 4]))
        #expect(model.points == [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 4)])
    }

    @Test func test_channel_names_are_carried() {
        let model = ScatterPanelModel(xChannel: "AccLat", yChannel: "AccLong",
                                      x: series([0, 1]), y: series([0, 1]))
        #expect(model.xChannel == "AccLat")
        #expect(model.yChannel == "AccLong")
    }

    // MARK: - Regression line (criterion 2: an optional least-squares fit)

    @Test func test_fit_is_computed_when_regression_is_on() throws {
        // y = 2x exactly → slope 2, intercept 0, a perfect fit.
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([0, 1, 2, 3]), y: series([0, 2, 4, 6]), regression: true)
        let fit = try #require(model.fit)
        #expect(fit.slope == 2)
        #expect(fit.intercept == 0)
        #expect(fit.r2 == 1)
    }

    @Test func test_regression_defaults_on() {
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([0, 1, 2]), y: series([0, 1, 2]))
        #expect(model.fit != nil, "the trend line is fitted by default")
    }

    @Test func test_no_fit_when_regression_is_off() {
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([0, 1, 2]), y: series([0, 2, 4]), regression: false)
        #expect(model.fit == nil)
    }

    @Test func test_no_fit_when_fewer_than_two_points_even_with_regression_on() {
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([5]), y: series([5]), regression: true)
        #expect(model.points.count == 1)
        #expect(model.fit == nil, "a single point has no line")
    }

    // MARK: - Window + empties

    @Test func test_window_restricts_the_cloud_to_the_basis_subset() {
        // The x-channel's xs is the basis: only samples whose basis is in [1, 2] pair.
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([10, 11, 12, 13], xs: [0, 1, 2, 3]),
                                      y: series([0, 1, 2, 3]),
                                      window: 1...2)
        #expect(model.points == [CGPoint(x: 11, y: 1), CGPoint(x: 12, y: 2)])
    }

    @Test func test_empty_series_yields_no_points_and_no_fit() {
        let model = ScatterPanelModel(xChannel: "x", yChannel: "y",
                                      x: series([]), y: series([]))
        #expect(model.points.isEmpty)
        #expect(model.fit == nil)
    }
}
