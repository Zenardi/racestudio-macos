import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelViewModel` (issue 7.2) — the plot layer's viewport-driven
/// min/max decimation, memoized per viewport.
@MainActor @Suite struct ChannelViewModelTests {

    /// A dense trace of `n` samples on a 100 Hz (ms) time axis, `distance == time`
    /// for simplicity, with a well-spread value so decimation has real min≠max.
    private func denseTrace(_ n: Int) -> ChannelTrace {
        let times = (0..<n).map { Double($0) * 10.0 }
        let values = (0..<n).map { sin(Double($0) * 0.017) * 100.0 + Double($0 % 251) * 0.3 }
        return ChannelTrace(name: "Speed", times: times, distances: times, values: values)
    }

    private func fullWindow(_ trace: ChannelTrace) -> ClosedRange<Double> {
        let xs = trace.xValues(mode: .time)
        return (xs.first ?? 0)...(xs.last ?? 0)
    }

    // MARK: - columns(forWidth:)

    @Test func test_columns_maps_viewport_width_to_pixel_columns() {
        #expect(ChannelViewModel.columns(forWidth: 199.6) == 200, "rounds to the nearest column")
        #expect(ChannelViewModel.columns(forWidth: 0) == 0, "no width, nothing to draw")
        #expect(ChannelViewModel.columns(forWidth: -5) == 0, "negative width is clamped to zero")
        #expect(ChannelViewModel.columns(forWidth: .nan) == 0, "NaN width is clamped to zero")
        #expect(ChannelViewModel.columns(forWidth: .infinity) == 0, "infinite width is clamped to zero")
        // A sub-pixel positive width still yields one column, so a visible viewport
        // is always decimated rather than falling back to the raw trace.
        #expect(ChannelViewModel.columns(forWidth: 0.3) == 1, "a sub-pixel width still draws one column")
        #expect(ChannelViewModel.columns(forWidth: 0.6) == 1)
        #expect(ChannelViewModel.columns(forWidth: 1_000_000) == ChannelViewModel.maxColumns,
                "an absurd width is capped at maxColumns")
        // A huge-but-finite width clamps to the cap without trapping the Int conversion.
        #expect(ChannelViewModel.columns(forWidth: 1e300) == ChannelViewModel.maxColumns,
                "a huge finite width clamps, never traps")
        #expect(ChannelViewModel.columns(forWidth: .greatestFiniteMagnitude) == ChannelViewModel.maxColumns)
    }

    @Test func test_decimated_sub_pixel_width_still_decimates() {
        // A momentarily sub-pixel viewport (a collapsing pane, or a width sentinel
        // before the first layout pass) must NOT hand the renderer the whole raw
        // trace — the exact stall issue 7.2 exists to prevent.
        let trace = denseTrace(50_000)
        let model = ChannelViewModel(trace: trace)
        let points = model.decimated(mode: .time, visible: fullWindow(trace), viewportWidth: 0.3)
        #expect(points.count < trace.samples.count, "a sub-pixel width is still decimated, not raw")
        #expect(!points.isEmpty, "one column still draws its min/max")
    }

    // MARK: - decimated(...)

    @Test func test_decimated_reduces_dense_trace_to_envelope() {
        let trace = denseTrace(2_000)
        let model = ChannelViewModel(trace: trace)
        let width = 200.0
        let points = model.decimated(mode: .time, visible: fullWindow(trace), viewportWidth: width)

        let columns = ChannelViewModel.columns(forWidth: width)
        #expect(points.count <= columns * 2, "at most a min/max pair per column")
        #expect(points.count >= columns, "each column emits at least one point")
        #expect(points.count < trace.samples.count, "the dense trace is decimated")
    }

    @Test func test_decimated_preserves_spike() {
        let times = (0..<10_000).map { Double($0) * 10.0 }
        var values = (0..<10_000).map { sin(Double($0) * 0.017) * 10.0 }
        let spike = 9_999.0
        values[5_432] = spike
        let trace = ChannelTrace(name: "Spike", times: times, distances: times, values: values)
        let model = ChannelViewModel(trace: trace)

        let points = model.decimated(mode: .time, visible: fullWindow(trace), viewportWidth: 300)
        #expect(points.contains { abs($0.y - spike) < 1e-9 }, "the spike survives decimation")
    }

    @Test func test_decimated_returns_raw_when_fewer_samples_than_columns() {
        // A window with fewer samples than columns is drawn at full detail.
        let trace = denseTrace(10)
        let model = ChannelViewModel(trace: trace)
        let points = model.decimated(mode: .time, visible: fullWindow(trace), viewportWidth: 500)
        #expect(points.count == trace.samples.count, "no decimation below the column count")
        #expect(points.map(\.y) == trace.samples.map(\.value), "raw values are passed through")
    }

    @Test func test_decimated_matches_shared_plot_polyline() {
        // The view model must draw the identical shape as the shared renderer path.
        let trace = denseTrace(1_000)
        let model = ChannelViewModel(trace: trace)
        let visible = fullWindow(trace)
        let width = 128.0
        let viaModel = model.decimated(mode: .distance, visible: visible, viewportWidth: width)
        let viaShared = plotPolyline(trace: trace, mode: .distance, visible: visible,
                                     columns: ChannelViewModel.columns(forWidth: width))
        #expect(viaModel == viaShared, "the view model delegates to plotPolyline unchanged")
    }

    @Test func test_decimated_memoizes_current_viewport() {
        let trace = denseTrace(2_000)
        let model = ChannelViewModel(trace: trace)
        let visible = fullWindow(trace)

        #expect(!model.isCached(mode: .time, visible: visible, viewportWidth: 200),
                "nothing is cached before the first request")
        let first = model.decimated(mode: .time, visible: visible, viewportWidth: 200)
        #expect(model.isCached(mode: .time, visible: visible, viewportWidth: 200),
                "the current viewport is memoized")

        // Re-reading the same viewport returns the identical result...
        let again = model.decimated(mode: .time, visible: visible, viewportWidth: 200)
        #expect(again == first, "a cache hit returns the same points")

        // ...and changing any viewport dimension invalidates the cache.
        _ = model.decimated(mode: .time, visible: visible, viewportWidth: 400)
        #expect(!model.isCached(mode: .time, visible: visible, viewportWidth: 200),
                "a new viewport width recomputes")
        #expect(model.isCached(mode: .time, visible: visible, viewportWidth: 400))
    }

    @Test func test_decimated_empty_trace_is_empty() {
        let model = ChannelViewModel(trace: ChannelTrace(name: "Empty", samples: []))
        #expect(model.decimated(mode: .time, visible: 0...1, viewportWidth: 300).isEmpty)
    }
}
