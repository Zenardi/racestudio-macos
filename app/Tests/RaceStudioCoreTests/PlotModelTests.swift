import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the plot model (issue 4.1) — x-axis mode, hit-testing, and the
/// min/max envelope shared by the Metal and Swift Charts render paths.
@Suite struct PlotModelTests {

    private func sampleTrace() -> ChannelTrace {
        ChannelTrace(
            name: "RPM",
            times: [0, 1, 2, 3],
            distances: [0, 10, 25, 40],
            values: [100, 200, 150, 300])
    }

    @Test func test_axis_mode_switch_preserves_samples() {
        let trace = sampleTrace()

        let times = trace.xValues(mode: .time)
        let distances = trace.xValues(mode: .distance)

        // Distance x-basis is the cumulative distance channel…
        #expect(distances == [0, 10, 25, 40])
        // …and switching to time re-maps the same samples with no data loss.
        #expect(times == [0, 1, 2, 3])
        #expect(times.count == trace.samples.count)
        #expect(distances.count == trace.samples.count)
        #expect(trace.samples.map(\.value) == [100, 200, 150, 300])

        // sample index → x for each mode.
        #expect(trace.x(at: 2, mode: .distance) == 25)
        #expect(trace.x(at: 2, mode: .time) == 2)
    }

    @Test func test_trace_id_is_its_name() {
        #expect(sampleTrace().id == "RPM")
    }

    @Test func test_x_at_out_of_range_index_is_nan_not_a_trap() {
        #expect(sampleTrace().x(at: 99, mode: .time).isNaN)
        #expect(sampleTrace().x(at: -1, mode: .distance).isNaN)
    }

    @Test func test_hittest_returns_nearest_index_and_nil_when_empty() {
        let xs: [Double] = [0, 10, 20, 30, 40]

        #expect(hitTest(x: 12, in: xs) == 1)   // nearest to 10
        #expect(hitTest(x: 16, in: xs) == 2)   // nearest to 20
        #expect(hitTest(x: 15, in: xs) == 1)   // exact tie → lower index
        #expect(hitTest(x: -5, in: xs) == 0)   // clamp below
        #expect(hitTest(x: 100, in: xs) == 4)  // clamp above
        #expect(hitTest(x: 0, in: xs) == 0)
        #expect(hitTest(x: 40, in: xs) == 4)

        // Empty series → nil, never a trap.
        #expect(hitTest(x: 5, in: [Double]()) == nil)

        // Convenience on ChannelTrace routes through the chosen x-basis.
        let trace = sampleTrace()
        #expect(trace.hitTest(x: 24, mode: .distance) == 2) // nearest distance is 25
        #expect(trace.hitTest(x: 0.4, mode: .time) == 0)    // nearest time is 0
        #expect(ChannelTrace(name: "e", samples: []).hitTest(x: 1, mode: .time) == nil)
    }

    @Test func test_dense_envelope_parity_min_max() throws {
        var values: [Double] = []
        values.reserveCapacity(50_000)
        for i in 0..<50_000 {
            values.append(sin(Double(i) * 0.01) * 1000)
        }
        let columns = 800

        let env = envelope(values: values, columns: columns)
        #expect(env.count == columns)
        #expect(env.count < values.count)
        for column in env {
            #expect(column.min <= column.max)
        }

        // The decimated envelope preserves the true global min/max…
        let globalMin = try #require(values.min())
        let globalMax = try #require(values.max())
        let envMin = try #require(env.map(\.min).min())
        let envMax = try #require(env.map(\.max).max())
        #expect(abs(envMin - globalMin) < 1e-9)
        #expect(abs(envMax - globalMax) < 1e-9)

        // …and is deterministic, so both render paths draw the identical shape.
        #expect(envelope(values: values, columns: columns) == env)
    }

    @Test func test_envelope_edge_cases() {
        #expect(envelope(values: [], columns: 10).isEmpty)
        #expect(envelope(values: [1, 2, 3], columns: 0).isEmpty)

        // More columns than samples clamps to one column per sample.
        let sparse = envelope(values: [5, 1, 9], columns: 10)
        #expect(sparse.count == 3)
        #expect(sparse[0] == ColumnExtent(min: 5, max: 5, minIndex: 0, maxIndex: 0))
        #expect(sparse[1] == ColumnExtent(min: 1, max: 1, minIndex: 1, maxIndex: 1))
        #expect(sparse[2] == ColumnExtent(min: 9, max: 9, minIndex: 2, maxIndex: 2))
    }

    // MARK: - plotPolyline (visible-window decimation shared by both renderers)

    /// A dense sine trace whose x-basis (time == distance here) is `0..<count`.
    private func denseTrace(count: Int) -> ChannelTrace {
        let times = (0..<count).map(Double.init)
        let values = (0..<count).map { sin(Double($0) * 0.05) * 1000 }
        return ChannelTrace(name: "dense", times: times, distances: times, values: values)
    }

    @Test func test_polyline_returns_raw_points_when_sparse() {
        let trace = sampleTrace() // 4 samples
        let points = plotPolyline(trace: trace, mode: .time, visible: 0...3, columns: 100)
        #expect(points.count == 4)
        #expect(points.map(\.x) == [0, 1, 2, 3])
        #expect(points.map(\.y) == [100, 200, 150, 300])
    }

    @Test func test_polyline_decimates_and_preserves_envelope_when_dense() throws {
        let trace = denseTrace(count: 10_000)
        let columns = 200
        let points = plotPolyline(trace: trace, mode: .distance, visible: 0...9_999, columns: columns)

        // At most two points (min+max) per column, and fewer than the samples.
        #expect(points.count <= columns * 2)
        #expect(points.count < 10_000)
        // Monotonic non-decreasing in x, all inside the window.
        for i in 1..<points.count {
            #expect(points[i].x >= points[i - 1].x)
        }
        #expect(points.allSatisfy { $0.x >= 0 && $0.x <= 9_999 })
        // The decimated envelope still spans the true global min/max.
        let allValues = trace.samples.map(\.value)
        let gMin = try #require(allValues.min())
        let gMax = try #require(allValues.max())
        let pMin = try #require(points.map(\.y).min())
        let pMax = try #require(points.map(\.y).max())
        #expect(abs(pMin - gMin) < 1e-9)
        #expect(abs(pMax - gMax) < 1e-9)
    }

    @Test func test_polyline_zoom_reveals_detail_within_window() {
        let trace = denseTrace(count: 10_000)
        let columns = 200

        let full = plotPolyline(trace: trace, mode: .distance, visible: 0...9_999, columns: columns)
        let zoomed = plotPolyline(trace: trace, mode: .distance, visible: 100...200, columns: columns)

        // Zoomed output stays inside the window…
        #expect(zoomed.allSatisfy { $0.x >= 100 && $0.x <= 200 })
        // …and shows more detail there than the whole-trace decimation did.
        let fullInWindow = full.filter { $0.x >= 100 && $0.x <= 200 }.count
        #expect(zoomed.count > fullInWindow)
    }

    @Test func test_polyline_empty_and_out_of_window_are_empty() {
        #expect(plotPolyline(trace: ChannelTrace(name: "e", samples: []),
                             mode: .time, visible: 0...1, columns: 10).isEmpty)
        // A window entirely past the data returns nothing (no trap).
        #expect(plotPolyline(trace: denseTrace(count: 100),
                             mode: .distance, visible: 5_000...6_000, columns: 10).isEmpty)
    }
}
