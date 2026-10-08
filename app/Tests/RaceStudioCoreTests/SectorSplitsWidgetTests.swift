import CoreGraphics
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the sector times widget's F1-style splits (issue 9.17): one row
/// per sector, a done sector's time and its gap to the best so far in purple
/// (best) or yellow (slower), the running sector highlighted, and a plate that
/// fits the session's sectors — legible up to eight of them.
@Suite struct SectorSplitsWidgetTests {

    private let theme = OverlayTheme.raceStudio

    /// Kart coaching's sector box in a 1920 × 1080 output.
    private let presetRect: CGRect = {
        let frame = OverlayPreset.kartCoaching.layout(locale: Locale(identifier: "en")).widgets
            .first { $0.kind == .sectorTimes }?.frame ?? NormalizedRect(x: 0, y: 0, width: 0, height: 0)
        return CGRect(x: 0, y: 0, width: (frame.width * 1920).rounded(), height: (frame.height * 1080).rounded())
    }()

    /// Three seconds into lap 5's S3: S1 beat lap 4's, S2 did not.
    private var lateLap: TelemetryFrame {
        let sectors = OverlayRenderFixture.sectors.laps[1].sectors
        return TelemetryFrame(time: sectors[2].span.start + 3, values: [:],
                              lap: OverlayRenderFixture.midLap.lap)
    }

    /// `frame` with its lap reading's sector bests replaced by `bests`.
    private func frame(_ frame: TelemetryFrame, bests: [Int: Double]) throws -> TelemetryFrame {
        let lap = try #require(frame.lap)
        return TelemetryFrame(time: frame.time, values: [:], lap: LapClockReading(
            lap: lap.lap, number: lap.number, elapsed: lap.elapsed, last: lap.last, best: lap.best,
            bestSoFar: lap.bestSoFar, isOutLap: lap.isOutLap, isInLap: lap.isInLap, sector: lap.sector,
            sectorBestsSoFar: bests))
    }

    /// A timeline of one lap cut into `count` sectors of 10 s.
    private func timeline(sectors count: Int) -> LapSectorTimeline {
        let lap = LapID(4)
        let start = OverlayRenderFixture.lapStart
        let sectors = (0..<count).map { index in
            SectorSpan(lap: lap, splitID: index, name: "S\(index + 1)", index: index,
                       span: SessionTimeSpan(start: start + Double(index) * 10, end: start + Double(index + 1) * 10))
        }
        return LapSectorTimeline(laps: [
            LapSpan(lap: lap, span: SessionTimeSpan(start: start, end: start + Double(count) * 10), sectors: sectors)
        ])
    }

    // MARK: - What each row says

    /// A done sector shows its time and its signed gap to the best so far; the
    /// running one its time so far; one still to come a dash.
    @Test func test_rows_show_the_time_and_the_gap_to_the_best_so_far() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect)

        #expect(SectorTimesWidget().readouts(lateLap, context: context)
            == ["S1", "15.532", "\u{2212}0.268", "S2", "16.500", "+0.400", "S3", "3.000"])
        #expect(SectorTimesWidget().readouts(OverlayRenderFixture.midLap, context: context)
            == ["S1", "15.532", "\u{2212}0.268", "S2", "2.900", "S3", "—"])
    }

    /// With nothing to compare with yet, a done sector shows its time alone.
    @Test func test_a_sector_with_nothing_to_compare_with_has_no_gap() throws {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect)

        #expect(SectorTimesWidget().readouts(try frame(lateLap, bests: [:]), context: context)
            == ["S1", "15.532", "S2", "16.500", "S3", "3.000"])
    }

    // MARK: - Colours

    /// The best-so-far sector is purple, the slower one yellow, the running one
    /// in the accent, each in its own row.
    @Test func test_best_is_purple_and_slower_is_yellow() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, plate: .none)
        let rows = SectorTimesWidget().layout(in: context).rows

        let bitmap = OverlayRenderFixture.render(SectorTimesWidget(), lateLap, context: context)

        #expect(bitmap.count(in: rows[0].frame) { $0.resembles(theme.sectorBest) } > 40)
        #expect(bitmap.count(in: rows[0].frame) { $0.resembles(theme.sectorSlower) } == 0)
        #expect(bitmap.count(in: rows[1].frame) { $0.resembles(theme.sectorSlower) } > 40)
        #expect(bitmap.count(in: rows[1].frame) { $0.resembles(theme.sectorBest) } == 0)
        #expect(bitmap.count(in: rows[2].frame) { $0.resembles(theme.accent) } > 20)
    }

    /// Each sector's bar carries its colour too, at the row's leading edge.
    @Test func test_each_row_has_a_bar_in_its_colour() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, plate: .none)
        let rows = SectorTimesWidget().layout(in: context).rows

        let bitmap = OverlayRenderFixture.render(SectorTimesWidget(), lateLap, context: context)

        #expect(rows.allSatisfy { $0.bar.maxX <= $0.name.minX && $0.bar.height > 0 })
        #expect(bitmap.count(in: rows[0].bar) { $0.resembles(theme.sectorBest) } > Int(rows[0].bar.width))
        #expect(bitmap.count(in: rows[1].bar) { $0.resembles(theme.sectorSlower) } > Int(rows[1].bar.width))
    }

    /// Without a best to compare with, nothing is purple or yellow.
    @Test func test_an_unrated_sector_is_neither_purple_nor_yellow() throws {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, plate: .none)

        let bitmap = OverlayRenderFixture.render(SectorTimesWidget(), try frame(lateLap, bests: [:]), context: context)

        #expect(bitmap.count { $0.resembles(theme.sectorBest, tolerance: 24) } == 0)
        #expect(bitmap.count { $0.resembles(theme.sectorSlower, tolerance: 24) } == 0)
    }

    // MARK: - Size

    /// Eight sectors stay legible in the preset's box at 1080p: eight rows
    /// stacked inside the plate without overlapping, text as tall as a lap-info
    /// row's, and the widest name, time and gap fitting their slots.
    @Test func test_eight_sectors_stay_legible() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, sectors: timeline(sectors: 8))
        let layout = SectorTimesWidget().layout(in: context)

        #expect(layout.rows.count == SectorTimesWidget.maximumRows)
        #expect(layout.rows.allSatisfy { layout.plate.contains($0.frame) })
        #expect(zip(layout.rows, layout.rows.dropFirst()).allSatisfy { $0.frame.minY >= $1.frame.maxY })
        #expect(layout.styles.time.capHeight >= 16, "\(layout.styles.time.capHeight) px")
        let slots = layout.rows[0]
        #expect(layout.styles.name.width(of: "S88") <= slots.name.width)
        #expect(layout.styles.time.width(of: "8:88.888") <= slots.time.width)
        #expect(layout.styles.gap.width(of: "+888.888") <= slots.gap.width)
    }

    /// The plate fits the session's sectors: three rows take the top of the
    /// box, and nothing is drawn below them.
    @Test func test_the_plate_fits_the_sessions_sectors() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect)
        let layout = SectorTimesWidget().layout(in: context)

        let bitmap = OverlayRenderFixture.render(SectorTimesWidget(), lateLap, context: context)

        #expect(layout.rows.count == 3)
        #expect(layout.plate.maxY == presetRect.maxY && layout.plate.height < presetRect.height / 2)
        let below = CGRect(x: presetRect.minX, y: presetRect.minY, width: presetRect.width,
                           height: layout.plate.minY - presetRect.minY)
        #expect(bitmap.count(in: below) { !$0.isTransparent } == 0)
        #expect(bitmap.count(in: layout.plate) { !$0.isTransparent } > 0)
    }

    /// Rows are the same size whatever the count, so three sectors are not
    /// drawn three times as tall as eight.
    @Test func test_rows_keep_their_size_whatever_the_count() {
        let three = SectorTimesWidget().layout(in: OverlayRenderFixture.context(.sectorTimes, rect: presetRect))
        let eight = SectorTimesWidget().layout(
            in: OverlayRenderFixture.context(.sectorTimes, rect: presetRect, sectors: timeline(sectors: 8)))

        #expect(three.rows[0].frame.height == eight.rows[0].frame.height)
    }

    /// A lap cut finer than eight sectors shows its first eight.
    @Test func test_more_than_eight_sectors_show_the_first_eight() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, sectors: timeline(sectors: 10))
        let frame = TelemetryFrame(time: OverlayRenderFixture.lapStart + 95, values: [:],
                                   lap: OverlayRenderFixture.midLap.lap)

        let readouts = SectorTimesWidget().readouts(frame, context: context)

        #expect(SectorTimesWidget().layout(in: context).rows.count == 8)
        #expect(readouts.filter { $0.hasPrefix("S") } == (1...8).map { "S\($0)" })
    }

    /// Without sectors, the plate holds one row, and the dash.
    @Test func test_without_sectors_the_plate_holds_one_row() {
        let context = OverlayRenderFixture.context(.sectorTimes, rect: presetRect, sectors: .empty)
        let layout = SectorTimesWidget().layout(in: context)

        #expect(layout.rows.count == 1)
        #expect(SectorTimesWidget().readouts(lateLap, context: context) == ["—"])
    }
}
