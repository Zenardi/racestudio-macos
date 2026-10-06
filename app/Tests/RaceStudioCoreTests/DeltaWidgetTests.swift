import CoreGraphics
import Testing
@testable import RaceStudioCore

/// The delta bar (issue 9.11): centred on zero, filled to the right in red
/// while losing time and to the left in green while gaining, clamped to its
/// ± range, with the signed delta written above it.
@Suite struct DeltaWidgetTests {

    private let widget = DeltaWidget()
    private let theme = OverlayTheme.raceStudio
    private let rect = CGRect(x: 0, y: 0, width: 420, height: 100)

    private func render(_ delta: Double?) -> (OverlayBitmap, DeltaWidget.Layout) {
        let context = OverlayRenderFixture.context(.delta, rect: rect,
                                                   options: OverlayWidgetOptions(deltaRange: 1))
        let frame = TelemetryFrame(time: 0, values: [:], delta: delta)
        return (OverlayRenderFixture.render(widget, frame, context: context), widget.layout(in: context))
    }

    private func left(of layout: DeltaWidget.Layout) -> CGRect {
        CGRect(x: layout.bar.minX, y: layout.bar.minY, width: layout.bar.width / 2 - 3, height: layout.bar.height)
    }

    private func right(of layout: DeltaWidget.Layout) -> CGRect {
        CGRect(x: layout.bar.midX + 3, y: layout.bar.minY, width: layout.bar.width / 2 - 3, height: layout.bar.height)
    }

    private func middleRow(of layout: DeltaWidget.Layout) -> CGRect {
        CGRect(x: 0, y: layout.bar.midY.rounded(.down), width: rect.width, height: 1)
    }

    // MARK: - What it reads

    @Test func test_a_gaining_delta_reads_with_a_minus_sign() {
        let context = OverlayRenderFixture.context(.delta)

        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context) == ["\u{2212}0.23"])
    }

    @Test func test_a_losing_delta_reads_with_a_plus_sign() {
        let context = OverlayRenderFixture.context(.delta)

        #expect(widget.readouts(OverlayRenderFixture.lapStartFrame, context: context) == ["+0.41"])
    }

    @Test func test_a_delta_gap_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.delta)

        #expect(widget.readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    // MARK: - Side and colour follow the sign

    @Test func test_losing_time_fills_red_to_the_right() {
        let (bitmap, layout) = render(0.3)

        #expect(bitmap.count(in: right(of: layout)) { $0.matches(self.theme.loss) } > 0)
        #expect(bitmap.count(in: left(of: layout)) { $0.matches(self.theme.loss) } == 0)
        #expect(bitmap.count(in: layout.bar) { $0.matches(self.theme.gain) } == 0)
    }

    @Test func test_gaining_time_fills_green_to_the_left() {
        let (bitmap, layout) = render(-0.3)

        #expect(bitmap.count(in: left(of: layout)) { $0.matches(self.theme.gain) } > 0)
        #expect(bitmap.count(in: right(of: layout)) { $0.matches(self.theme.gain) } == 0)
        #expect(bitmap.count(in: layout.bar) { $0.matches(self.theme.loss) } == 0)
    }

    @Test func test_the_fill_is_in_proportion_to_the_range() {
        let (bitmap, layout) = render(0.3)

        let filled = bitmap.count(in: middleRow(of: layout)) { $0.matches(self.theme.loss) }

        #expect(abs(filled - Int((layout.bar.width / 2 * 0.3).rounded())) <= 1)
    }

    @Test func test_a_loss_beyond_the_range_clamps_to_the_bar_end() {
        let (bitmap, layout) = render(5)

        let filled = bitmap.positions(in: middleRow(of: layout)) { $0.matches(self.theme.loss) }

        #expect(abs(filled.count - Int((layout.bar.width / 2).rounded())) <= 1)
        #expect((filled.map(\.x).max() ?? .infinity) < layout.bar.maxX)
    }

    @Test func test_a_gain_beyond_the_range_clamps_to_the_bar_end() {
        let (bitmap, layout) = render(-5)

        let filled = bitmap.positions(in: middleRow(of: layout)) { $0.matches(self.theme.gain) }

        #expect(abs(filled.count - Int((layout.bar.width / 2).rounded())) <= 1)
        #expect((filled.map(\.x).min() ?? -.infinity) > layout.bar.minX)
    }

    @Test func test_the_number_takes_the_colour_of_the_sign() {
        let (losing, layout) = render(0.3)
        let (gaining, _) = render(-0.3)

        #expect(losing.count(in: layout.value) { $0.resembles(self.theme.loss) } > 30)
        #expect(gaining.count(in: layout.value) { $0.resembles(self.theme.gain) } > 30)
    }

    @Test func test_a_gap_fills_nothing() {
        let (bitmap, layout) = render(nil)

        #expect(bitmap.count(in: layout.bar) { $0.matches(self.theme.loss) || $0.matches(self.theme.gain) } == 0)
    }

    @Test func test_an_even_delta_fills_nothing() {
        let (bitmap, layout) = render(0)

        #expect(bitmap.count(in: layout.bar) { $0.matches(self.theme.loss) || $0.matches(self.theme.gain) } == 0)
    }
}
