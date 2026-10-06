import CoreGraphics
import Testing
@testable import RaceStudioCore

/// The RPM widget (issue 9.11): the engine speed in digits over a bar filled
/// to the widget's full scale, with a shift light lit at or above its threshold.
@Suite struct RPMWidgetTests {

    private let widget = RPMWidget()
    private let theme = OverlayTheme.raceStudio
    private let options = OverlayWidgetOptions(maxRPM: 16_000, shiftLightRPM: 14_000)

    private func frame(rpm: Double?) -> TelemetryFrame {
        TelemetryFrame(time: 0, values: rpm.map { [.rpm: $0] } ?? [:])
    }

    private func render(rpm: Double?) -> (OverlayBitmap, RPMWidget.Layout) {
        let context = OverlayRenderFixture.context(.rpm, rect: CGRect(x: 0, y: 0, width: 400, height: 90),
                                                   options: options)
        return (OverlayRenderFixture.render(widget, frame(rpm: rpm), context: context), widget.layout(in: context))
    }

    private func isLit(_ bitmap: OverlayBitmap, _ layout: RPMWidget.Layout) -> Bool {
        bitmap.pixel(at: CGPoint(x: layout.shiftLight.midX, y: layout.shiftLight.midY)).matches(theme.warning)
    }

    /// How far along the bar's middle row the accent fill reaches.
    private func filledWidth(_ bitmap: OverlayBitmap, _ layout: RPMWidget.Layout) -> Int {
        let row = CGRect(x: 0, y: layout.bar.midY.rounded(.down), width: CGFloat(bitmap.width), height: 1)
        return bitmap.count(in: row) { $0.matches(self.theme.accent) }
    }

    // MARK: - What it reads

    @Test func test_rpm_reads_whole_revolutions_without_grouping() {
        let context = OverlayRenderFixture.context(.rpm)

        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context) == ["12850"])
    }

    @Test func test_an_rpm_gap_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.rpm)

        #expect(widget.readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    // MARK: - Shift light

    @Test func test_the_shift_light_is_off_below_the_threshold() {
        let (bitmap, layout) = render(rpm: 13_999)

        #expect(!isLit(bitmap, layout))
    }

    @Test func test_the_shift_light_is_on_at_the_threshold() {
        let (bitmap, layout) = render(rpm: 14_000)

        #expect(isLit(bitmap, layout))
    }

    @Test func test_the_shift_light_is_on_above_the_threshold() {
        let (bitmap, layout) = render(rpm: 15_500)

        #expect(isLit(bitmap, layout))
    }

    @Test func test_the_shift_light_is_off_in_a_gap() {
        let (bitmap, layout) = render(rpm: nil)

        #expect(!isLit(bitmap, layout))
    }

    // MARK: - Bar

    @Test func test_the_bar_fills_in_proportion_to_full_scale() {
        let (bitmap, layout) = render(rpm: 8_000)

        #expect(abs(filledWidth(bitmap, layout) - Int((layout.bar.width / 2).rounded())) <= 1)
    }

    @Test func test_the_bar_clamps_at_full_scale() {
        let (bitmap, layout) = render(rpm: 40_000)

        #expect(abs(filledWidth(bitmap, layout) - Int(layout.bar.width)) <= 1)
        #expect(bitmap.count(in: CGRect(x: layout.bar.maxX + 1, y: layout.bar.minY, width: 2,
                                        height: layout.bar.height)) { $0.matches(self.theme.accent) } == 0)
    }

    @Test func test_the_bar_is_empty_in_a_gap() {
        let (bitmap, layout) = render(rpm: nil)

        #expect(filledWidth(bitmap, layout) == 0)
    }

    @Test func test_the_bar_and_light_sit_inside_the_widget() {
        let context = OverlayRenderFixture.context(.rpm, rect: CGRect(x: 0, y: 0, width: 400, height: 90))

        let layout = widget.layout(in: context)

        #expect(context.content.contains(layout.bar))
        #expect(context.content.contains(layout.shiftLight))
        #expect(layout.bar.maxX < layout.shiftLight.minX)
    }
}
