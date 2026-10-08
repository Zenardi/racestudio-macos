import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the F1-style sector splits' data (issue 9.17): each sector's best
/// time so far, kept by ``LapClock`` from the laps completed *before* an
/// instant, and ``SectorSplit``, which says for each sector of the lap under the
/// instant whether it is done (with its gap to that best, purple or yellow),
/// running or still to come.
@Suite struct SectorSplitTests {

    // MARK: - Fixtures

    /// An out-lap, three flying laps and an in-lap, each cut into three
    /// sectors (S1, S2, S3, split ids 0, 1, 2):
    ///
    ///     L0 out [0,60)    18    15    27      (S2 the fastest of all)
    ///     L1     [60,110)  16    17    17
    ///     L2     [110,158) 15.5  17.5  15
    ///     L3     [158,207) 16.25 16.75 16
    ///     L4 in  [207,270) 14    25    24      (S1 the fastest of all)
    private let grids: [(start: Double, sectors: [Double])] = [
        (0, [18, 15, 27]), (60, [16, 17, 17]), (110, [15.5, 17.5, 15]),
        (158, [16.25, 16.75, 16]), (207, [14, 25, 24])
    ]

    private func laps() -> [Lap] {
        grids.enumerated().map { index, lap in
            let duration = lap.sectors.reduce(0, +)
            return Lap(index: UInt32(index), startTimeS: lap.start, durationS: duration,
                       endTimeS: lap.start + duration)
        }
    }

    private func timeline() -> LapSectorTimeline {
        LapSectorTimeline.make(
            laps: laps(),
            segments: grids.indices.map { LapSegments(lap: LapID($0), baseTimes: grids[$0].sectors) },
            layout: SplitLayout.even(base: 3, count: 3))
    }

    private func clock() -> LapClock {
        LapClock(laps: laps(), sectors: timeline())
    }

    /// The sector splits at session time `t`.
    private func splits(at t: Double) throws -> [SectorSplit] {
        let reading = try #require(clock().reading(at: t))
        let lap = try #require(timeline().lapSpan(reading.lap))
        return SectorSplit.splits(of: lap, at: t, reading: reading)
    }

    /// A reading of a flying lap holding `bests`.
    private func reading(bests: [Int: Double], isOutLap: Bool = false, isInLap: Bool = false) -> LapClockReading {
        LapClockReading(lap: LapID(9), number: 10, elapsed: 0, last: nil, best: nil, bestSoFar: nil,
                        isOutLap: isOutLap, isInLap: isInLap, sector: nil, sectorBestsSoFar: bests)
    }

    /// A lap of one sector `[0, time)`.
    private func oneSector(_ time: Double) -> LapSpan {
        let span = SessionTimeSpan(start: 0, end: time)
        return LapSpan(lap: LapID(9), span: span,
                       sectors: [SectorSpan(lap: LapID(9), splitID: 0, name: "S1", index: 0, span: span)])
    }

    // MARK: - Best so far per sector

    /// Before any lap has been completed there is no best.
    @Test func test_no_sector_best_before_a_lap_is_completed() throws {
        #expect(try #require(clock().reading(at: 30)).sectorBestsSoFar.isEmpty)
    }

    /// The out-lap's sectors never set a best, even its fastest-of-all S2.
    @Test func test_the_out_lap_sets_no_sector_best() throws {
        #expect(try #require(clock().reading(at: 70)).sectorBestsSoFar.isEmpty)
    }

    /// Each sector's best is the fastest of the counted laps completed before
    /// the instant's lap.
    @Test func test_each_sector_best_comes_from_the_laps_completed_before() throws {
        let clock = clock()

        #expect(try #require(clock.reading(at: 120)).sectorBestsSoFar == [0: 16, 1: 17, 2: 17])
        #expect(try #require(clock.reading(at: 170)).sectorBestsSoFar == [0: 15.5, 1: 17, 2: 15])
        #expect(try #require(clock.reading(at: 220)).sectorBestsSoFar == [0: 15.5, 1: 16.75, 2: 15])
    }

    /// A sector finished on the current lap is not a best until the lap is
    /// completed: the video never shows a best that hasn't happened yet.
    @Test func test_the_current_lap_does_not_set_its_own_bests() throws {
        let bests = try #require(clock().reading(at: 157.9)).sectorBestsSoFar

        #expect(bests == [0: 16, 1: 17, 2: 17], "lap 2's 15.5 and 15 are not bests yet")
    }

    /// A sector with no time (a split with no cells) never sets a best of zero.
    @Test func test_an_empty_sector_sets_no_best() throws {
        let laps = [Lap(index: 0, startTimeS: 0, durationS: 50, endTimeS: 50),
                    Lap(index: 1, startTimeS: 50, durationS: 50, endTimeS: 100),
                    Lap(index: 2, startTimeS: 100, durationS: 50, endTimeS: 150),
                    Lap(index: 3, startTimeS: 150, durationS: 50, endTimeS: 200)]
        let sectors = LapSectorTimeline.make(
            laps: laps, segments: (0..<4).map { LapSegments(lap: LapID($0), baseTimes: [0, 20, 30]) },
            layout: SplitLayout.even(base: 3, count: 3))

        let bests = try #require(LapClock(laps: laps, sectors: sectors).reading(at: 160)).sectorBestsSoFar

        #expect(bests == [1: 20, 2: 30])
    }

    // MARK: - Purple, yellow and the gap

    /// A finished sector at or under the best so far is purple with a negative
    /// gap; one over it is yellow with a positive gap; the running sector
    /// counts up; the next one is still to come.
    @Test func test_done_sectors_compare_with_the_best_so_far() throws {
        let splits = try splits(at: 150)

        #expect(splits == [
            SectorSplit(name: "S1", progress: .done(time: 15.5, gap: -0.5, pace: .best)),
            SectorSplit(name: "S2", progress: .done(time: 17.5, gap: 0.5, pace: .slower)),
            SectorSplit(name: "S3", progress: .running(elapsed: 7))
        ])
    }

    /// Equalling the best so far is purple, with a zero gap.
    @Test func test_equalling_the_best_is_purple() {
        let splits = SectorSplit.splits(of: oneSector(15.5), at: 20, reading: reading(bests: [0: 15.5]))

        #expect(splits == [SectorSplit(name: "S1", progress: .done(time: 15.5, gap: 0, pace: .best))])
    }

    /// The comparison is made on the thousandths shown, so the colour always
    /// agrees with the gap's text: a gap that reads `0.000` is purple.
    @Test func test_the_comparison_is_made_on_the_thousandths_shown() {
        let tie = SectorSplit.splits(of: oneSector(15.5004), at: 20, reading: reading(bests: [0: 15.4996]))
        let slower = SectorSplit.splits(of: oneSector(15.5011), at: 20, reading: reading(bests: [0: 15.4996]))

        #expect(tie.first?.progress == .done(time: 15.5004, gap: 0, pace: .best))
        #expect(slower.first?.progress == .done(time: 15.5011, gap: 0.001, pace: .slower))
    }

    /// With nothing to compare with yet, a finished sector is neutral and has
    /// no gap — colour is never the only signal.
    @Test func test_a_sector_with_nothing_to_compare_with_is_unrated() throws {
        let splits = try splits(at: 100)

        #expect(splits[0] == SectorSplit(name: "S1", progress: .done(time: 16, gap: nil, pace: .unrated)))
        #expect(splits[1] == SectorSplit(name: "S2", progress: .done(time: 17, gap: nil, pace: .unrated)))
    }

    /// The out-lap's and the in-lap's sectors are shown, but neither beats a
    /// best: the in-lap's S1 of 14 s is the fastest of all, yet unrated.
    @Test func test_out_and_in_lap_sectors_are_unrated() throws {
        let outLap = try splits(at: 59)
        let inLap = try splits(at: 230)

        #expect(outLap[1] == SectorSplit(name: "S2", progress: .done(time: 15, gap: nil, pace: .unrated)))
        #expect(inLap[0] == SectorSplit(name: "S1", progress: .done(time: 14, gap: nil, pace: .unrated)))
    }

    /// An empty sector is shown done, but never compared.
    @Test func test_an_empty_sector_is_unrated() {
        let splits = SectorSplit.splits(of: oneSector(0), at: 0, reading: reading(bests: [0: 15]))

        #expect(splits == [SectorSplit(name: "S1", progress: .done(time: 0, gap: nil, pace: .unrated))])
    }

    // MARK: - The lap line

    /// On the lap line the splits start again: the new lap's S1 runs from zero
    /// and every other sector is still to come.
    @Test func test_the_splits_reset_at_the_lap_line() throws {
        let splits = try splits(at: 110)

        #expect(splits == [
            SectorSplit(name: "S1", progress: .running(elapsed: 0)),
            SectorSplit(name: "S2", progress: .upcoming),
            SectorSplit(name: "S3", progress: .upcoming)
        ])
    }

    /// The session's last instant closes the final lap: every sector is done.
    @Test func test_the_last_instant_finishes_every_sector() throws {
        let splits = try splits(at: 270)

        #expect(splits.allSatisfy { if case .done = $0.progress { return true } else { return false } })
    }
}
