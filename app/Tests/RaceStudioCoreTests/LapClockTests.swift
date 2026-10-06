import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `LapClock` (issue 9.9): at any session time, which lap the kart is
/// on, how long it has been on it, its last and best lap, whether it is the out-
/// or in-lap, and which sector it is in — the lap timer and lap-info widgets'
/// data. "Best" is the one shared rule (`SessionSummaryViewModel.bestLapIndex`),
/// so the overlay can never disagree with the Summary or the library.
@Suite struct LapClockTests {

    // MARK: - Fixtures

    /// Out-lap, two flying laps, an undecodable lap (a hole), a lap tying the
    /// best, and an in-lap:
    ///
    ///     L0 [100,182) 82 s · L1 [182,235) 53 s · L2 [235,285) 50 s
    ///     L3 [285,335) NaN  · L4 [335,385) 50 s · L5 [385,445) 60 s
    private func laps() -> [Lap] {
        [lap(0, 100, 82), lap(1, 182, 53), lap(2, 235, 50),
         Lap(index: 3, startTimeS: 285, durationS: .nan, endTimeS: 335),
         lap(4, 335, 50), lap(5, 385, 60)]
    }

    private func lap(_ index: UInt32, _ start: Double, _ duration: Double) -> Lap {
        Lap(index: index, startTimeS: start, durationS: duration, endTimeS: start + duration)
    }

    /// Lap 1 cut into three sectors: [182,192) [192,212) [212,235).
    private func sectors() -> LapSectorTimeline {
        LapSectorTimeline.make(laps: laps(), segments: [LapSegments(lap: LapID(1), baseTimes: [10, 20, 23])],
                               layout: SplitLayout.even(base: 3, count: 3))
    }

    private func clock() -> LapClock {
        LapClock(laps: laps(), sectors: sectors())
    }

    // MARK: - Lap and elapsed time

    /// Given `t` inside a lap, then the reading names the lap (1-based number,
    /// as the lap list shows it) and the time elapsed since its beacon.
    @Test func test_inside_a_lap_reports_its_number_and_elapsed_time() throws {
        let reading = try #require(clock().reading(at: 200))

        #expect(reading.lap == LapID(1))
        #expect(reading.number == 2)
        #expect(abs(reading.elapsed - 18) < 1e-9)
    }

    /// Exactly on a beacon, the instant belongs to the lap that starts there
    /// (elapsed 0), not the one that ends.
    @Test func test_exactly_on_the_beacon_belongs_to_the_new_lap() throws {
        let reading = try #require(clock().reading(at: 182))

        #expect(reading.lap == LapID(1))
        #expect(reading.elapsed == 0)
    }

    /// The session's very last instant closes the final lap rather than falling
    /// off the end of the half-open windows (the `LapSectorTimeline` rule).
    @Test func test_the_last_instant_closes_the_final_lap() throws {
        let reading = try #require(clock().reading(at: 445))

        #expect(reading.lap == LapID(5))
        #expect(reading.elapsed == 60)
    }

    /// Before the first lap, after the last, inside an undecodable lap, or at a
    /// non-finite time, there is no lap to report.
    @Test func test_outside_every_valid_lap_reads_nil() {
        let clock = clock()

        #expect(clock.reading(at: 99.9) == nil)
        #expect(clock.reading(at: 445.001) == nil)
        #expect(clock.reading(at: 300) == nil, "lap 3 has no valid duration")
        #expect(clock.reading(at: .nan) == nil)
        #expect(LapClock(laps: []).reading(at: 0) == nil)
    }

    // MARK: - Out / in laps

    /// The session's first lap is the out-lap and its last the in-lap; laps in
    /// between are neither.
    @Test func test_out_lap_and_in_lap_are_flagged() throws {
        let clock = clock()

        let out = try #require(clock.reading(at: 150))
        let flying = try #require(clock.reading(at: 250))
        let inLap = try #require(clock.reading(at: 400))
        #expect(out.isOutLap && !out.isInLap)
        #expect(!flying.isOutLap && !flying.isInLap)
        #expect(inLap.isInLap && !inLap.isOutLap)
    }

    /// A single-lap session's only lap is its out-lap; it is not also an in-lap.
    @Test func test_a_single_lap_is_only_the_out_lap() throws {
        let reading = try #require(LapClock(laps: [lap(0, 0, 40)]).reading(at: 10))

        #expect(reading.isOutLap)
        #expect(!reading.isInLap)
    }

    // MARK: - Last and best

    /// "Last" is the most recent completed lap with a valid time — an
    /// undecodable lap in between is skipped — and the first lap has none.
    @Test func test_last_lap_is_the_previous_valid_lap() throws {
        let clock = clock()

        #expect(try #require(clock.reading(at: 120)).last == nil)
        #expect(try #require(clock.reading(at: 200)).last == LapTiming(lap: LapID(0), number: 1, time: 82))
        #expect(try #require(clock.reading(at: 340)).last == LapTiming(lap: LapID(2), number: 3, time: 50))
    }

    /// The session best is the Summary's best lap — fastest valid lap, earliest
    /// on a tie — at every instant of the session.
    @Test func test_best_lap_is_the_one_the_summary_flags() throws {
        let clock = clock()
        let summaryBest = try #require(SessionSummaryViewModel.bestLapIndex(laps()))

        #expect(clock.best == LapTiming(lap: LapID(summaryBest), number: summaryBest + 1, time: 50))
        #expect(clock.best?.lap == LapID(2), "lap 4 ties at 50 s; the earlier lap wins")
        #expect(try #require(clock.reading(at: 120)).best == clock.best, "the session best is known from the start")
    }

    /// "Best so far" applies the same rule only to the laps completed before the
    /// current one — what a live lap timer shows.
    @Test func test_best_so_far_counts_only_completed_laps() throws {
        let clock = clock()

        #expect(try #require(clock.reading(at: 120)).bestSoFar == nil)
        #expect(try #require(clock.reading(at: 200)).bestSoFar?.lap == LapID(0))
        #expect(try #require(clock.reading(at: 250)).bestSoFar?.lap == LapID(1))
        #expect(try #require(clock.reading(at: 400)).bestSoFar?.lap == LapID(2))
    }

    /// With no valid lap at all, there is no best lap.
    @Test func test_no_valid_lap_means_no_best() {
        #expect(LapClock(laps: [Lap(index: 0, startTimeS: 0, durationS: 0, endTimeS: 0)]).best == nil)
    }

    // MARK: - Sector

    /// The sector comes from the split timeline (half-open: a boundary opens the
    /// next sector); a lap the timeline did not divide has none.
    @Test func test_sector_comes_from_the_split_timeline() throws {
        let clock = clock()

        #expect(try #require(clock.reading(at: 185)).sector?.name == "S1")
        #expect(try #require(clock.reading(at: 192)).sector?.name == "S2")
        #expect(try #require(clock.reading(at: 234.9)).sector?.index == 2)
        #expect(try #require(clock.reading(at: 250)).sector == nil, "lap 2 has no base grid")
    }

    // MARK: - Malformed laps

    /// Overlapping windows are cut at the next lap's beacon (it opens the next
    /// lap), a reversed window is dropped, and of two laps starting together the
    /// later-listed one holds the time — so hinted and fresh reads agree.
    @Test func test_overlapping_and_reversed_laps_read_consistently() throws {
        let laps = [lap(0, 0, 10), lap(1, 5, 10), Lap(index: 2, startTimeS: 20, durationS: 5, endTimeS: 18),
                    lap(3, 30, 5), lap(4, 30, 3)]
        let clock = LapClock(laps: laps)

        #expect(try #require(clock.reading(at: 7)).lap == LapID(1), "lap 1's beacon opens lap 1")
        #expect(clock.reading(at: 19) == nil, "a reversed window holds nothing")
        #expect(try #require(clock.reading(at: 31)).lap == LapID(4))
        for start in [-1, 0, 1, 2, Int.max] {
            var hint = start
            for t in stride(from: -1.0, to: 36, by: 0.25) {
                #expect(clock.reading(at: t, hint: &hint) == clock.reading(at: t), "hint \(start) t \(t)")
            }
        }
    }

    // MARK: - Hint cursor

    /// Property: reading with a carried hint equals a fresh reading at every
    /// instant, for a forward sweep and a shuffled seek sequence.
    @Test func test_hint_reading_equals_random_reading() {
        var rng = SeededGenerator(seed: 9)
        let clock = clock()
        let sweep = (0..<1200).map { 95 + Double($0) * 0.3 }

        for queries in [sweep, sweep.shuffled(using: &rng)] {
            var hint = 0
            for t in queries {
                #expect(clock.reading(at: t, hint: &hint) == clock.reading(at: t), "t \(t)")
            }
        }
    }
}
