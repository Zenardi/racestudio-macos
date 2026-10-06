import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `LiveDelta` (issue 9.9): the running gap to a reference lap at a
/// session instant, read off the 3.2 delta-t series (`delta_t_series`) by how far
/// into its lap the kart is. The sign is the delta-t strip's: positive = slower
/// than the reference (losing), negative = gaining.
@Suite struct LiveDeltaTests {

    // MARK: - Fixtures

    /// A session odometer sampled every 0.1 s:
    /// - lap 0 `[0, 9.95)`: 10 m/s, its fixes covering 0 → 99 m;
    /// - lap 1 `[9.95, 21)`: its first fix at 10 s, its fixes covering 99 m
    ///   (100 → 199 m) in 10.9 s;
    /// - lap 2 `[21, 31)`: twice as far, 198 m (200 → 398 m) in 9.9 s.
    private func odometer() -> TelemetrySeries {
        var times: [Double] = []
        var distances: [Double] = []
        for step in 0..<100 { times.append(Double(step) / 10); distances.append(Double(step)) }
        for step in 0..<110 { times.append(10 + Double(step) / 10); distances.append(100 + Double(step) * 99 / 109) }
        for step in 0..<100 { times.append(21 + Double(step) / 10); distances.append(200 + Double(step) * 2) }
        return TelemetrySeries(times: times, values: distances)
    }

    private func laps() -> [Lap] {
        [Lap(index: 0, startTimeS: 0, durationS: 9.95, endTimeS: 9.95),
         Lap(index: 1, startTimeS: 9.95, durationS: 11.05, endTimeS: 21),
         Lap(index: 2, startTimeS: 21, durationS: 10, endTimeS: 31)]
    }

    /// Canned `delta_t_series(reference, lap)` output on the reference's 99 m grid.
    private static let lapOneVsZero = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 33, dt: 0.2),
                                       DeltaSample(distance: 66, dt: -0.5), DeltaSample(distance: 99, dt: 1.0)]
    private static let lapTwoVsZero = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 99, dt: -0.1)]
    private static let lapZeroVsOne = [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 99, dt: -1.0)]

    /// A provider answering from the canned series, counting its calls.
    private final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var callCount: Int { lock.withLock { calls.count } }
        var lastCall: String? { lock.withLock { calls.last } }

        func series(_ reference: LapID, _ lap: LapID) -> [DeltaSample] {
            lock.withLock { calls.append("\(reference.index)→\(lap.index)") }
            switch (reference.index, lap.index) {
            case (0, 1): return LiveDeltaTests.lapOneVsZero
            case (0, 2): return LiveDeltaTests.lapTwoVsZero
            case (1, 0): return LiveDeltaTests.lapZeroVsOne
            default: return []
            }
        }
    }

    private func delta(reference: LapID? = LapID(0), provider: Provider = Provider()) -> LiveDelta {
        LiveDelta(reference: reference, laps: laps(), distance: odometer()) { provider.series($0, $1) }
    }

    /// The session time at which lap 1 is `lapDistance` metres past its first fix.
    private func lapOneTime(atLapDistance lapDistance: Double) -> Double {
        10 + lapDistance / (99.0 / 10.9)
    }

    // MARK: - Reference lap

    /// Along the reference lap itself the delta is exactly zero — the kart is
    /// its own reference — without asking the core for a series.
    @Test func test_the_reference_lap_reads_zero() {
        let provider = Provider()
        let live = delta(provider: provider)

        for t in stride(from: 0.0, to: 10, by: 0.7) {
            #expect(live.delta(at: t, lap: LapID(0)) == 0)
        }
        #expect(provider.callCount == 0)
    }

    // MARK: - Reading the series

    /// At the instants where the lap reaches the series' own sample distances,
    /// the delta is exactly that sample's `dt` — sign included (negative =
    /// gaining on the reference, as the delta-t strip draws it).
    @Test(arguments: [(33.0, 0.2), (66.0, -0.5), (99.0, 1.0)])
    func test_delta_matches_the_series_at_its_sample_distances(distance: Double, dt: Double) throws {
        let reading = try #require(delta().delta(at: lapOneTime(atLapDistance: distance), lap: LapID(1)))

        #expect(abs(reading - dt) < 1e-9)
    }

    /// Between the series' samples the delta is interpolated linearly by distance.
    @Test func test_delta_interpolates_between_series_samples() throws {
        let reading = try #require(delta().delta(at: lapOneTime(atLapDistance: 16.5), lap: LapID(1)))

        #expect(abs(reading - 0.1) < 1e-9)
    }

    /// A lap that covered a different distance is compared at the same *fraction*
    /// of the lap, as `delta_t` itself aligns the two laps: halfway round the
    /// 198 m lap is halfway along the reference's 99 m grid.
    @Test func test_a_longer_lap_is_compared_by_lap_fraction() throws {
        let halfway = try #require(delta().delta(at: 21 + 4.95, lap: LapID(2)))

        #expect(abs(halfway - (-0.05)) < 1e-9)
    }

    /// Between the beacon and the lap's first fix the kart has covered no lap
    /// distance yet (delta 0); after its last fix it holds the final delta.
    @Test func test_lap_distance_is_clamped_to_the_lap() throws {
        let live = delta()

        #expect(try #require(live.delta(at: 20.95, lap: LapID(1))) == 1.0)
        #expect(live.delta(at: 9.97, lap: LapID(1)) == 0, "past the beacon, before the first fix")
    }

    // MARK: - Missing data

    /// No reference, no odometer reading at `t`, an empty series, or a lap that
    /// covered no distance: the delta is unknown (`nil`), never zero.
    @Test func test_missing_inputs_read_nil() {
        let flat = TelemetrySeries(times: [0, 0.1, 10, 10.1], values: [0, 0, 0, 0])
        let noDistance = LiveDelta(reference: LapID(1), laps: laps(), distance: flat) { _, _ in Self.lapZeroVsOne }

        #expect(delta(reference: nil).delta(at: 15, lap: LapID(1)) == nil)
        #expect(delta().delta(at: 40, lap: LapID(1)) == nil, "no odometer reading at t")
        #expect(delta(reference: LapID(2)).delta(at: 15, lap: LapID(1)) == nil, "the core had no series")
        #expect(noDistance.delta(at: 0.05, lap: LapID(0)) == nil, "the lap covered no distance")
        #expect(delta().delta(at: 15, lap: LapID(7)) == nil, "an unknown lap")
    }

    /// A lap holding no odometer fix, or an odometer running backwards across a
    /// lap, has no lap distance to read the series by.
    @Test func test_a_lap_without_usable_fixes_reads_nil() {
        let sliver = Lap(index: 3, startTimeS: 5.01, durationS: 0.05, endTimeS: 5.06)
        let between = LiveDelta(reference: LapID(0), laps: laps() + [sliver], distance: odometer()) { _, _ in
            Self.lapOneVsZero
        }
        let backwards = TelemetrySeries(times: [10, 10.1, 10.2, 21], values: [150, 100, 120, 130])
        let reversed = LiveDelta(reference: LapID(0), laps: laps(), distance: backwards) { _, _ in Self.lapOneVsZero }

        #expect(between.delta(at: 5.03, lap: LapID(3)) == nil, "no fix inside the lap window")
        #expect(reversed.delta(at: 10.05, lap: LapID(1)) == nil, "the odometer ran backwards")
    }

    // MARK: - Caching and reference switching

    /// Each lap's series is fetched once, however many frames read it.
    @Test func test_each_lap_series_is_fetched_once() {
        let provider = Provider()
        let live = delta(provider: provider)

        for t in stride(from: 10.0, to: 31, by: 0.05) {
            _ = live.delta(at: t, lap: t < 21 ? LapID(1) : LapID(2))
        }
        #expect(provider.callCount == 2)
    }

    /// Prefetching fetches every lap but the reference up front, so the export
    /// path never waits on the core mid-render.
    @Test func test_prefetch_fetches_every_other_lap_once() throws {
        let provider = Provider()
        let live = delta(provider: provider)

        try live.prefetch()
        try live.prefetch()
        _ = live.delta(at: 15, lap: LapID(1))

        #expect(provider.callCount == 2, "laps 1 and 2; the reference needs no series")
    }

    /// A lap the core has no series for is remembered as such: asked once.
    @Test func test_a_lap_without_a_series_is_fetched_once() {
        let provider = Provider()
        let live = delta(reference: LapID(2), provider: provider)

        for t in stride(from: 10.0, to: 21, by: 0.5) {
            #expect(live.delta(at: t, lap: LapID(1)) == nil)
        }
        #expect(provider.callCount == 1)
    }

    /// Prefetching stops with `CancellationError` when its task is cancelled.
    @Test func test_prefetch_is_cancellable() async {
        let live = delta()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try live.prefetch()
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Eight readers racing on a cold cache all read the single-threaded deltas.
    @Test func test_concurrent_reads_on_a_cold_cache_agree() async {
        let instants = Array(stride(from: 10.0, to: 31, by: 0.1))
        let expected = instants.map { delta().delta(at: $0, lap: $0 < 21 ? LapID(1) : LapID(2)) }
        let live = delta()

        let results = await withTaskGroup(of: [Double?].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var hints = LiveDelta.Hints()
                    return instants.map { live.delta(at: $0, lap: $0 < 21 ? LapID(1) : LapID(2), hints: &hints) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        for deltas in results { #expect(deltas == expected) }
    }

    /// Switching the reference recomputes: the new reference reads zero, and the
    /// old reference is now compared against it with a freshly fetched series.
    @Test func test_switching_the_reference_recomputes() throws {
        let provider = Provider()
        let live = delta(provider: provider)
        _ = live.delta(at: 15, lap: LapID(1))

        let switched = live.referencing(LapID(1))

        #expect(switched.reference == LapID(1))
        #expect(switched.delta(at: 15, lap: LapID(1)) == 0)
        let reading = try #require(switched.delta(at: 9.9, lap: LapID(0)))
        #expect(abs(reading - (-1.0)) < 1e-9)
        #expect(provider.lastCall == "1→0")
        #expect(live.reference == LapID(0), "the original is unchanged")
    }

    // MARK: - Hints

    /// Property: a forward sweep with carried hints reads exactly what fresh
    /// reads give.
    @Test func test_hinted_reads_equal_fresh_reads() {
        let live = delta()
        var hints = LiveDelta.Hints()

        for t in stride(from: 10.0, to: 31, by: 0.033) {
            let lap = t < 21 ? LapID(1) : LapID(2)
            #expect(live.delta(at: t, lap: lap, hints: &hints) == live.delta(at: t, lap: lap), "t \(t)")
        }
    }
}
