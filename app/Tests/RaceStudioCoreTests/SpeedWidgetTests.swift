import CoreGraphics
import Testing
@testable import RaceStudioCore

/// The speed widget (issue 9.11): big whole-number digits over the unit, on a
/// plate that keeps them legible over any footage.
@Suite struct SpeedWidgetTests {

    private let widget = SpeedWidget()

    private func isText(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.resembles(OverlayTheme.raceStudio.text)
    }

    // MARK: - What it reads

    @Test func test_speed_reads_whole_kilometres_per_hour() {
        let context = OverlayRenderFixture.context(.speed)

        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context) == ["87"])
    }

    @Test func test_speed_follows_the_widget_units() {
        let context = OverlayRenderFixture.context(.speed, units: .imperial)

        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context) == ["54"])
    }

    @Test func test_a_speed_gap_reads_an_em_dash() {
        let context = OverlayRenderFixture.context(.speed)

        #expect(widget.readouts(OverlayRenderFixture.gap, context: context) == ["—"])
    }

    // MARK: - Where it draws

    @Test func test_the_digits_are_drawn_in_the_value_slot() {
        let context = OverlayRenderFixture.context(.speed, plate: .none)
        let layout = widget.layout(in: context)

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context,
                                                 parts: .dynamicOnly)

        let ink = bitmap.bounds { !$0.isTransparent }
        #expect(bitmap.count(where: isText) > 200)
        #expect(layout.value.insetBy(dx: -2, dy: -2).contains(ink ?? .null))
    }

    @Test func test_a_gap_draws_a_dash_and_no_digits() {
        let context = OverlayRenderFixture.context(.speed, plate: .none)
        let layout = widget.layout(in: context)

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context,
                                                 parts: .dynamicOnly)

        let ink = bitmap.bounds { !$0.isTransparent }
        #expect(ink != nil)
        #expect((ink?.height ?? .infinity) < layout.valueStyle.capHeight / 3)
    }

    @Test func test_the_unit_is_drawn_once_with_the_static_parts() {
        let context = OverlayRenderFixture.context(.speed, plate: .none)
        let layout = widget.layout(in: context)

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context,
                                                 parts: .staticOnly)

        let ink = bitmap.bounds { !$0.isTransparent }
        #expect(ink != nil)
        #expect(layout.unit.insetBy(dx: -2, dy: -2).contains(ink ?? .null))
    }

    @Test func test_the_translucent_plate_covers_the_widget() {
        let context = OverlayRenderFixture.context(.speed)

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context,
                                                 parts: .staticOnly)

        let edge = bitmap.pixel(at: CGPoint(x: context.rect.midX, y: context.rect.minY + 1))
        #expect(abs(Int(edge.alpha) - Int((OverlayTheme.raceStudio.translucentPlateOpacity * 255).rounded())) <= 1)
    }

    // MARK: - Legibility

    /// Given the translucent plate, when the overlay is laid over pure white or
    /// pure black footage, then the digits keep WCAG AA contrast (≥ 4.5:1)
    /// against the plate as it is actually rasterised.
    @Test(arguments: [BrandColor.rgb(255, 255, 255), BrandColor.rgb(0, 0, 0)])
    func test_digits_stay_legible_on_the_plate_over_bright_and_dark_footage(_ footage: BrandColor) throws {
        let context = OverlayRenderFixture.context(.speed)
        let layout = widget.layout(in: context)
        let overlay = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context)
        let image = try #require(overlay.context.makeImage())
        let composite = OverlayBitmap(width: overlay.width, height: overlay.height)
        composite.context.setFillColor(CGColor(srgbRed: footage.red, green: footage.green, blue: footage.blue,
                                               alpha: 1))
        composite.context.fill(composite.bounds)
        composite.context.draw(image, in: composite.bounds)

        let plate = composite.pixel(at: CGPoint(x: context.rect.midX, y: context.rect.minY + 1)).color
        let brightest = composite.positions(in: layout.value) { _ in true }
            .map { composite.pixel(at: $0).color }
            .max { $0.relativeLuminance < $1.relativeLuminance }
        let digits = try #require(brightest)
        #expect(digits.contrastRatio(against: plate) >= 4.5)
    }
}
