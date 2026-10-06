import CoreGraphics
import Testing
@testable import RaceStudioCore

/// The mini track map (issue 9.11): the racing line fitted into the widget
/// (north up, turned by the widget's rotation), sector ticks on it, and the
/// kart's position dot.
@Suite struct TrackMapWidgetTests {

    private let widget = TrackMapWidget()
    private let theme = OverlayTheme.raceStudio
    private let square = OverlayTrackMap(racingLine: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1),
                                                      CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0)])

    private func context(track: OverlayTrackMap, rotation: Double = 0) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.trackMap, rect: CGRect(x: 0, y: 0, width: 220, height: 220), plate: .none,
                                     options: OverlayWidgetOptions(trackMapRotation: rotation), track: track)
    }

    private func frame(at point: CGPoint?) -> TelemetryFrame {
        TelemetryFrame(time: 0, values: [:], position: point.map { TrackPositionReading(point: $0, heading: nil) })
    }

    private func isDot(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.matches(theme.accent, tolerance: 8)
    }

    // MARK: - What it reads

    @Test func test_a_placed_kart_writes_nothing() {
        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context(track: square)).isEmpty)
    }

    @Test func test_a_position_gap_reads_an_em_dash() {
        #expect(widget.readouts(OverlayRenderFixture.gap, context: context(track: square)) == ["—"])
    }

    @Test func test_a_position_that_is_not_a_number_reads_an_em_dash() {
        let frame = frame(at: CGPoint(x: Double.nan, y: 0.5))

        #expect(widget.readouts(frame, context: context(track: square)) == ["—"])
    }

    @Test func test_racing_line_points_that_are_not_numbers_are_left_out() {
        let map = OverlayTrackMap(racingLine: [CGPoint(x: 0, y: 0), CGPoint(x: Double.nan, y: 1), CGPoint(x: 1, y: 1)],
                                  sectorTicks: [CGPoint(x: 0.5, y: Double.infinity), CGPoint(x: 0.5, y: 0.5)])

        #expect(map.racingLine == [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        #expect(map.sectorTicks == [CGPoint(x: 0.5, y: 0.5)])
    }

    // MARK: - The dot

    @Test func test_the_dot_sits_at_its_projected_pixel() throws {
        let context = context(track: square)
        let area = widget.layout(in: context).area
        let side = min(area.width, area.height)

        let bitmap = OverlayRenderFixture.render(widget, frame(at: CGPoint(x: 0.25, y: 0.75)), context: context,
                                                 parts: .dynamicOnly)

        // North up: map y grows southwards, drawing y upwards.
        let expected = CGPoint(x: area.midX - 0.25 * side, y: area.midY - 0.25 * side)
        #expect(try #require(bitmap.centroid(where: isDot)).distance(to: expected) <= 2)
    }

    @Test func test_the_map_turns_clockwise_by_its_rotation() throws {
        let context = context(track: square, rotation: 90)
        let area = widget.layout(in: context).area
        let side = min(area.width, area.height)

        let bitmap = OverlayRenderFixture.render(widget, frame(at: CGPoint(x: 0.25, y: 0.75)), context: context,
                                                 parts: .dynamicOnly)

        // South-west of centre turns a quarter clockwise to north-west.
        let expected = CGPoint(x: area.midX - 0.25 * side, y: area.midY + 0.25 * side)
        #expect(try #require(bitmap.centroid(where: isDot)).distance(to: expected) <= 2)
    }

    @Test func test_a_kart_off_the_map_is_held_inside_the_widget() throws {
        let context = context(track: square)
        let area = widget.layout(in: context).area

        let bitmap = OverlayRenderFixture.render(widget, frame(at: CGPoint(x: 5, y: -4)), context: context,
                                                 parts: .dynamicOnly)

        #expect(area.insetBy(dx: -1, dy: -1).contains(try #require(bitmap.centroid(where: isDot))))
        #expect(context.rect.contains(bitmap.bounds { !$0.isTransparent } ?? .null))
    }

    @Test func test_without_a_racing_line_the_dot_is_placed_on_the_unit_frame() throws {
        let context = context(track: .empty)
        let area = widget.layout(in: context).area
        let side = min(area.width, area.height)

        let bitmap = OverlayRenderFixture.render(widget, frame(at: CGPoint(x: 0.25, y: 0.75)), context: context)

        let expected = CGPoint(x: area.midX - 0.25 * side, y: area.midY - 0.25 * side)
        #expect(try #require(bitmap.centroid(where: isDot)).distance(to: expected) <= 2)
    }

    @Test func test_a_racing_line_without_extent_centres_the_map_on_it() throws {
        let point = CGPoint(x: 0.3, y: 0.7)
        let context = context(track: OverlayTrackMap(racingLine: [point, point]))
        let area = widget.layout(in: context).area

        let bitmap = OverlayRenderFixture.render(widget, frame(at: point), context: context, parts: .dynamicOnly)

        #expect(try #require(bitmap.centroid(where: isDot)).distance(to: CGPoint(x: area.midX, y: area.midY)) <= 2)
    }

    @Test func test_a_gap_draws_no_dot() {
        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context(track: square),
                                                 parts: .dynamicOnly)

        #expect(bitmap.count(where: isDot) == 0)
        #expect(bitmap.count { !$0.isTransparent } > 0)
    }

    // MARK: - The line and its ticks

    @Test func test_the_racing_line_is_drawn_with_the_static_parts() {
        let context = context(track: square)
        let area = widget.layout(in: context).area
        let side = min(area.width, area.height)

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context,
                                                 parts: .staticOnly)

        let northEdge = CGPoint(x: area.midX, y: area.midY + side / 2)
        #expect(!bitmap.pixel(at: northEdge).isTransparent)
        #expect(bitmap.pixel(at: CGPoint(x: area.midX, y: area.midY)).isTransparent)
    }

    @Test func test_sector_ticks_mark_the_line() {
        let ticked = OverlayTrackMap(racingLine: square.racingLine, sectorTicks: [CGPoint(x: 1, y: 0.5)])
        let context = context(track: ticked)
        let area = widget.layout(in: context).area
        let side = min(area.width, area.height)

        let plain = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: self.context(track: square),
                                                parts: .staticOnly)
        let marked = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context,
                                                 parts: .staticOnly)

        let tick = CGPoint(x: area.midX + side / 2, y: area.midY)
        let near = CGRect(x: tick.x - 4, y: tick.y - 4, width: 8, height: 8)
        let isTick: (OverlayBitmap.Pixel) -> Bool = { $0.resembles(self.theme.secondaryText, tolerance: 30) }
        #expect(marked.count(in: near, where: isTick) > plain.count(in: near, where: isTick))
    }

    // MARK: - Built from a session's timeline

    @Test func test_a_session_map_is_its_best_lap_with_a_tick_at_each_sector_start() async throws {
        let built = TelemetryFixture.make()
        let timeline = try await TelemetryTimeline.load(session: built.session, source: built.source,
                                                        sectors: built.sectors)

        let map = OverlayTrackMap(timeline: timeline, sectors: built.sectors)

        // The best lap (index 1, 21–40 s) is cut in halves: one boundary, at 30.5 s.
        let boundary = try #require(timeline.position.reading(at: 30.5)?.point)
        #expect(map.racingLine == timeline.position.racingLine)
        #expect(map.sectorTicks == [boundary])
    }

    @Test func test_a_session_without_sectors_has_no_ticks() async throws {
        let built = TelemetryFixture.make()
        let timeline = try await TelemetryTimeline.load(session: built.session, source: built.source)

        #expect(OverlayTrackMap(timeline: timeline, sectors: .empty).sectorTicks.isEmpty)
    }
}
