import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The gear and lap widgets (issue 9.11): the gear, the running lap timer, lap
/// N · last · best, and the current lap's sector times.
@Suite struct LapWidgetTests {

    private let brazilian = OverlayFormatter(locale: Locale(identifier: "pt_BR"))

    // MARK: - Gear

    @Test func test_gear_reads_the_gear_number() {
        let context = OverlayRenderFixture.context(.gear)

        #expect(GearWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["3"])
    }

    @Test func test_gear_zero_reads_neutral() {
        let context = OverlayRenderFixture.context(.gear)

        #expect(GearWidget().readouts(TelemetryFrame(time: 0, values: [.gear: 0]), context: context) == ["N"])
    }

    @Test func test_a_gear_gap_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.gear)

        #expect(GearWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    @Test func test_the_gear_label_follows_the_export_language() {
        #expect(GearWidget.label(OverlayRenderFixture.context(.gear)) == "GEAR")
        #expect(GearWidget.label(OverlayRenderFixture.context(.gear, formatter: brazilian)) == "MARCHA")
    }

    // MARK: - Lap timer

    @Test func test_the_lap_timer_runs_from_the_beacon() {
        let context = OverlayRenderFixture.context(.lapTimer)

        #expect(LapTimerWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["0:18.432"])
    }

    @Test func test_the_lap_timer_restarts_at_the_line() {
        let context = OverlayRenderFixture.context(.lapTimer)

        #expect(LapTimerWidget().readouts(OverlayRenderFixture.lapStartFrame, context: context) == ["0:00.400"])
    }

    @Test func test_the_lap_timer_writes_the_export_decimal_mark() {
        let context = OverlayRenderFixture.context(.lapTimer, formatter: brazilian)

        #expect(LapTimerWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["0:18,432"])
    }

    @Test func test_the_lap_timer_outside_a_lap_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.lapTimer)

        #expect(LapTimerWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    // MARK: - Lap info

    @Test func test_lap_info_reads_lap_last_and_best_so_far() {
        let context = OverlayRenderFixture.context(.lapInfo)

        #expect(LapInfoWidget().readouts(OverlayRenderFixture.midLap, context: context)
            == ["5", "0:47.912", "0:46.881"])
    }

    @Test func test_lap_info_at_the_start_of_a_lap_shows_the_lap_just_finished() {
        let context = OverlayRenderFixture.context(.lapInfo)

        #expect(LapInfoWidget().readouts(OverlayRenderFixture.lapStartFrame, context: context)
            == ["5", "0:47.912", "0:46.881"])
    }

    @Test func test_lap_info_on_the_first_lap_has_no_last_or_best() {
        let context = OverlayRenderFixture.context(.lapInfo)
        let first = LapClockReading(lap: LapID(0), number: 1, elapsed: 3, last: nil, best: nil, bestSoFar: nil,
                                    isOutLap: true, isInLap: false, sector: nil)

        #expect(LapInfoWidget().readouts(TelemetryFrame(time: 3, values: [:], lap: first), context: context)
            == ["1", "—", "—"])
    }

    @Test func test_lap_info_outside_a_lap_reads_em_dashes() {
        let context = OverlayRenderFixture.context(.lapInfo)

        #expect(LapInfoWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—", "—", "—"])
    }

    @Test func test_lap_info_labels_follow_the_export_language() {
        #expect(LapInfoWidget.labels(OverlayRenderFixture.context(.lapInfo)) == ["LAP", "LAST", "BEST"])
        #expect(LapInfoWidget.labels(OverlayRenderFixture.context(.lapInfo, formatter: brazilian))
            == ["VOLTA", "ÚLTIMA", "MELHOR"])
    }

    @Test func test_lap_info_rows_stack_inside_the_widget() {
        let context = OverlayRenderFixture.context(.lapInfo)

        let rows = LapInfoWidget().layout(in: context).rows

        #expect(rows.count == 3)
        #expect(rows.allSatisfy { context.content.contains($0) })
        #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.minY >= $1.maxY })
    }

    // MARK: - Sector times

    @Test func test_sector_times_show_done_running_and_pending_sectors() {
        let context = OverlayRenderFixture.context(.sectorTimes)

        #expect(SectorTimesWidget().readouts(OverlayRenderFixture.midLap, context: context)
            == ["S1", "15.532", "S2", "2.900", "S3", "—"])
    }

    @Test func test_sector_times_at_the_start_of_a_lap_run_the_first_sector() {
        let context = OverlayRenderFixture.context(.sectorTimes)

        #expect(SectorTimesWidget().readouts(OverlayRenderFixture.lapStartFrame, context: context)
            == ["S1", "0.400", "S2", "—", "S3", "—"])
    }

    @Test func test_a_sector_just_entered_runs_from_zero() {
        let context = OverlayRenderFixture.context(.sectorTimes)
        let lap = LapClockReading(lap: LapID(4), number: 5, elapsed: 15.532, last: nil, best: nil, bestSoFar: nil,
                                  isOutLap: false, isInLap: false, sector: nil)
        let frame = TelemetryFrame(time: OverlayRenderFixture.sectors.laps[1].sectors[1].span.start, values: [:],
                                   lap: lap)

        #expect(SectorTimesWidget().readouts(frame, context: context)
            == ["S1", "15.532", "S2", "0.000", "S3", "—"])
    }

    @Test func test_sector_times_outside_a_lap_read_an_em_dash() {
        let context = OverlayRenderFixture.context(.sectorTimes)

        #expect(SectorTimesWidget().readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    @Test func test_a_lap_the_split_timeline_does_not_divide_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.sectorTimes, sectors: .empty)

        #expect(SectorTimesWidget().readouts(OverlayRenderFixture.midLap, context: context) == ["—"])
    }

    @Test func test_the_running_sector_is_highlighted() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: CGRect(x: 0, y: 0, width: 240, height: 150),
                                                   plate: .none)
        let rows = SectorTimesWidget().layout(in: context).rows(for: 3)

        let bitmap = OverlayRenderFixture.render(SectorTimesWidget(), OverlayRenderFixture.midLap, context: context)

        let accent = OverlayTheme.raceStudio.accent
        #expect(bitmap.count(in: rows[1]) { $0.resembles(accent) } > 20)
        #expect(bitmap.count(in: rows[0]) { $0.resembles(accent) } == 0)
    }
}
