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

        // Identity and an out-of-range index that must not trap.
        #expect(trace.id == trace.name)
        #expect(trace.x(at: 99, mode: .time).isNaN)
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
}
