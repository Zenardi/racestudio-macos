import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ShockVelocity` (issue 8.17): the derived shock/damper-velocity math
/// channel — the time-derivative of a suspension-position channel. Mirrors the
/// Rust `derived.rs` policy: a backward difference in units/second, the first
/// sample 0 (no predecessor), and a non-positive `dt` guarded to 0 so a duplicated
/// or back-stepped timecode never yields ±∞/NaN.
@Suite struct ShockVelocityTests {

    /// Position sampled at a fixed 100 Hz (10 ms) with a constant slope `k`, so the
    /// exact velocity is `k` at every sample after the first.
    private func ramp(slope k: Double, count: Int, dt: Double = 0.01) -> [DataSample] {
        (0..<count).map { DataSample(time: Double($0) * dt, value: Double($0) * dt * k) }
    }

    @Test func test_derivative_of_a_linear_ramp_is_the_constant_slope() {
        let velocity = ShockVelocity.derivative(of: ramp(slope: 5, count: 4))

        #expect(velocity.count == 4)
        #expect(velocity[0].value == 0, "the first sample has no predecessor to difference against")
        for i in 1..<velocity.count {
            #expect(abs(velocity[i].value - 5) < 1e-9, "constant-slope position differentiates to a constant")
        }
    }

    @Test func test_derivative_preserves_the_sample_times() {
        let position = ramp(slope: 1, count: 3)
        let velocity = ShockVelocity.derivative(of: position)
        #expect(velocity.map(\.time) == position.map(\.time))
    }

    @Test func test_non_uniform_spacing_uses_each_pairs_own_dt() {
        // Times 0, 1, 3 s; values 0, 10, 30 → per-pair slopes 10 and 10.
        let position = [DataSample(time: 0, value: 0),
                        DataSample(time: 1, value: 10),
                        DataSample(time: 3, value: 30)]
        let velocity = ShockVelocity.derivative(of: position)
        #expect(velocity[0].value == 0)
        #expect(abs(velocity[1].value - 10) < 1e-9)   // 10 / 1
        #expect(abs(velocity[2].value - 10) < 1e-9)   // 20 / 2
    }

    @Test func test_zero_dt_duplicate_timecode_is_guarded_to_zero() {
        // A repeated timecode (dt == 0) must not divide by zero.
        let position = [DataSample(time: 0, value: 0),
                        DataSample(time: 0, value: 5)]
        let velocity = ShockVelocity.derivative(of: position)
        #expect(velocity[1].value == 0)
        #expect(velocity.allSatisfy { $0.value.isFinite })
    }

    @Test func test_backward_stepping_timecode_is_guarded_to_zero() {
        // A negative dt (a back-stepped timecode) is guarded to 0, never ±∞.
        let position = [DataSample(time: 1, value: 0),
                        DataSample(time: 0, value: 5)]
        let velocity = ShockVelocity.derivative(of: position)
        #expect(velocity[1].value == 0)
        #expect(velocity.allSatisfy { $0.value.isFinite })
    }

    @Test func test_empty_input_yields_empty_series() {
        #expect(ShockVelocity.derivative(of: []).isEmpty)
    }

    @Test func test_single_sample_has_zero_velocity() {
        let velocity = ShockVelocity.derivative(of: [DataSample(time: 2, value: 9)])
        #expect(velocity == [DataSample(time: 2, value: 0)])
    }

    // MARK: - Plottable trace

    @Test func test_trace_is_named_and_time_keyed_for_plotting() {
        let trace = ShockVelocity.trace(channel: "Shock_FL", position: ramp(slope: 2, count: 3))

        #expect(trace.name == "Shock_FL Velocity")
        #expect(trace.samples.count == 3)
        // A derived math channel is time-keyed, so distance mirrors time.
        #expect(trace.samples.allSatisfy { $0.time == $0.distance })
        #expect(trace.samples.first?.value == 0)
    }

    @Test func test_trace_values_match_the_derivative() {
        let position = ramp(slope: 3, count: 3)
        let trace = ShockVelocity.trace(channel: "S", position: position)
        let expected = ShockVelocity.derivative(of: position).map(\.value)
        #expect(trace.samples.map(\.value) == expected)
    }

    @Test func test_trace_from_a_channel_trace_differentiates_its_time_samples() {
        // The suspension composite overlays velocity from an existing position trace.
        let position = ChannelTrace(name: "Shock_FR",
                                    times: [0, 0.01, 0.02], distances: [0, 5, 10], values: [0, 1, 2])
        let velocity = ShockVelocity.trace(from: position)

        #expect(velocity.name == "Shock_FR Velocity")
        #expect(velocity.samples.map(\.time) == [0, 0.01, 0.02], "the derivative keeps the source's time base")
        #expect(velocity.samples.first?.value == 0)
        // (1 - 0) / (0.01 - 0) = 100 units/s.
        #expect(abs((velocity.samples[1].value) - 100) < 1e-6)
    }
}
