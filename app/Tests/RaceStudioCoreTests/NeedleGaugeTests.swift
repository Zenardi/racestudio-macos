import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The needle gauges (issue 9.15): a tachometer and a speedometer drawn as
/// dials — a 240° scale from lower left over the top to lower right, labelled
/// ticks, a needle, and the value in digits inside the dial — so RPM and speed
/// read like a car's instrument cluster.
@Suite struct NeedleGaugeTests {

    private let theme = OverlayTheme.raceStudio
    private let tachometer = TachometerWidget()
    private let speedometer = SpeedometerWidget()

    private func tachContext(maxRPM: Double = 16_000, shift: Double = 14_000) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.rpm, rect: CGRect(x: 0, y: 0, width: 240, height: 240), plate: .none,
                                     options: OverlayWidgetOptions(maxRPM: maxRPM, shiftLightRPM: shift,
                                                                   gaugeStyle: .needle))
    }

    private func speedContext(maxSpeed: Double = 160, units: UnitSystem = .metric) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.speed, rect: CGRect(x: 0, y: 0, width: 240, height: 240), plate: .none,
                                     units: units, options: OverlayWidgetOptions(gaugeStyle: .needle,
                                                                                 maxSpeed: maxSpeed))
    }

    private func rpm(_ value: Double?) -> TelemetryFrame {
        TelemetryFrame(time: 0, values: value.map { [.rpm: $0] } ?? [:])
    }

    private func speed(_ value: Double?) -> TelemetryFrame {
        TelemetryFrame(time: 0, values: value.map { [.speed: $0] } ?? [:])
    }

    /// The point `share` of the radius out along the scale at `fraction`.
    private func along(_ fraction: Double, _ share: CGFloat, on dial: DialLayout) -> CGPoint {
        let angle = Dial.angle(fraction: fraction)
        return CGPoint(x: dial.centre.x + cos(angle) * dial.radius * share,
                       y: dial.centre.y + sin(angle) * dial.radius * share)
    }

    /// A 4 × 4 box round `point`.
    private func near(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
    }

    private func isNeedle(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.matches(theme.accent, tolerance: 8)
    }

    private func isRedZone(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.matches(theme.loss, tolerance: 8)
    }

    /// Whether the needle covers the scale at `fraction`, halfway out.
    private func needle(at fraction: Double, in bitmap: OverlayBitmap, on dial: DialLayout) -> Bool {
        bitmap.count(in: near(along(fraction, 0.55, on: dial)), where: isNeedle) > 0
    }

    // MARK: - The scale

    /// The scale runs 240° clockwise from lower left (210°) over the top (90°)
    /// to lower right (−30°).
    @Test func test_the_scale_sweeps_240_degrees_over_the_top() {
        #expect(abs(Dial.angle(fraction: 0) - 210 * .pi / 180) < 1e-9)
        #expect(abs(Dial.angle(fraction: 0.5) - .pi / 2) < 1e-9)
        #expect(abs(Dial.angle(fraction: 1) + 30 * .pi / 180) < 1e-9)
    }

    /// Major ticks at the smallest 1, 2 or 5 × 10ⁿ step that cuts the scale into
    /// at most ten parts.
    @Test(arguments: zip([16_000.0, 9_000, 12_000, 30_000, 160, 99.4, 60], [2_000.0, 1_000, 2_000, 5_000, 20, 10, 10]))
    func test_major_ticks_fall_on_a_round_step(full: Double, step: Double) {
        #expect(DialScale(maximum: full).step == step)
    }

    @Test func test_the_scale_labels_every_major_tick_up_to_full_scale() {
        #expect(DialScale(maximum: 99.4).values == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90])
    }

    /// A scale with no usable full scale (zero or not a number) is just its zero.
    @Test(arguments: [0.0, -5, .nan, .infinity])
    func test_a_scale_without_a_usable_full_scale_is_just_zero(_ full: Double) {
        let scale = DialScale(maximum: full)

        #expect(scale.values == [0])
        #expect(scale.step == 1)
    }

    // MARK: - Tachometer

    @Test func test_the_tachometer_reads_whole_revolutions() {
        #expect(tachometer.readouts(OverlayRenderFixture.midLap, context: tachContext()) == ["12850"])
        #expect(tachometer.readouts(OverlayRenderFixture.gap, context: tachContext()) == ["—"])
    }

    /// Its ticks are labelled in thousands, with a `×1000 RPM` caption.
    @Test func test_the_tachometer_labels_its_scale_in_thousands() {
        let layout = tachometer.layout(in: tachContext(maxRPM: 16_000))

        #expect(layout.dial.labels.map(\.text) == ["0", "2", "4", "6", "8", "10", "12", "14", "16"])
        #expect(TachometerWidget.caption == "×1000 RPM")
    }

    @Test(arguments: [4_000.0, 8_000, 12_000])
    func test_the_needle_points_at_the_rpm(_ value: Double) {
        let context = tachContext()
        let dial = tachometer.layout(in: context).dial

        let bitmap = OverlayRenderFixture.render(tachometer, rpm(value), context: context, parts: .dynamicOnly)

        #expect(needle(at: value / 16_000, in: bitmap, on: dial))
        #expect(!needle(at: value < 8_000 ? 1 : 0, in: bitmap, on: dial), "the far end of the scale")
    }

    /// Past full scale the needle stops at full scale; the digits read the real rpm.
    @Test func test_past_full_scale_the_needle_stops_but_the_digits_do_not() {
        let context = tachContext()
        let dial = tachometer.layout(in: context).dial

        let bitmap = OverlayRenderFixture.render(tachometer, rpm(19_500), context: context, parts: .dynamicOnly)

        #expect(needle(at: 1, in: bitmap, on: dial))
        #expect(tachometer.readouts(rpm(19_500), context: context) == ["19500"])
    }

    /// Without an rpm there is no needle at all, and the digits read `—`.
    @Test func test_a_gap_draws_no_needle() {
        let bitmap = OverlayRenderFixture.render(tachometer, rpm(nil), context: tachContext(), parts: .dynamicOnly)

        #expect(bitmap.count(where: isNeedle) == 0)
    }

    /// The red zone runs from the shift-light rpm to full scale, drawn once.
    /// Probed between ticks, at 14 500 and 6 500 rpm.
    @Test func test_the_red_zone_runs_from_the_shift_light_to_full_scale() {
        let context = tachContext(maxRPM: 16_000, shift: 12_000)
        let dial = tachometer.layout(in: context).dial

        let still = OverlayRenderFixture.render(tachometer, rpm(nil), context: context, parts: .staticOnly)

        #expect(still.count(in: near(along(14_500 / 16_000, 0.93, on: dial)), where: isRedZone) > 0)
        #expect(still.count(in: near(along(6_500 / 16_000, 0.93, on: dial)), where: isRedZone) == 0)
    }

    @Test(arguments: zip([13_999.0, 14_000, 15_500], [false, true, true]))
    func test_the_shift_light_is_lit_at_the_threshold(_ value: Double, _ lit: Bool) {
        let context = tachContext()
        let light = tachometer.layout(in: context).shiftLight

        let bitmap = OverlayRenderFixture.render(tachometer, rpm(value), context: context)

        #expect(bitmap.pixel(at: CGPoint(x: light.midX, y: light.midY)).matches(theme.warning) == lit)
    }

    @Test func test_the_shift_light_is_off_in_a_gap() {
        let context = tachContext()
        let light = tachometer.layout(in: context).shiftLight

        let bitmap = OverlayRenderFixture.render(tachometer, rpm(nil), context: context)

        #expect(!bitmap.pixel(at: CGPoint(x: light.midX, y: light.midY)).matches(theme.warning))
    }

    // MARK: - Speedometer

    @Test func test_the_speedometer_reads_whole_units() {
        #expect(speedometer.readouts(OverlayRenderFixture.midLap, context: speedContext()) == ["87"])
        #expect(speedometer.readouts(OverlayRenderFixture.midLap, context: speedContext(units: .imperial)) == ["54"])
        #expect(speedometer.readouts(OverlayRenderFixture.gap, context: speedContext()) == ["—"])
    }

    /// The scale is labelled in the layout's units, up to the max speed.
    @Test func test_the_speedometer_labels_its_scale_in_the_layouts_units() {
        let metric = speedometer.layout(in: speedContext(maxSpeed: 160))
        let imperial = speedometer.layout(in: speedContext(maxSpeed: 160, units: .imperial))

        #expect(metric.dial.labels.map(\.text) == ["0", "20", "40", "60", "80", "100", "120", "140", "160"])
        #expect(imperial.dial.labels.map(\.text) == ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90"])
        #expect(SpeedometerWidget.caption(speedContext()) == "km/h")
        #expect(SpeedometerWidget.caption(speedContext(units: .imperial)) == "mph")
    }

    @Test func test_the_speedometer_needle_points_at_the_speed() {
        let context = speedContext(maxSpeed: 160)
        let dial = speedometer.layout(in: context).dial

        let bitmap = OverlayRenderFixture.render(speedometer, speed(40), context: context, parts: .dynamicOnly)

        #expect(needle(at: 0.25, in: bitmap, on: dial))
        #expect(!needle(at: 1, in: bitmap, on: dial))
    }

    @Test func test_past_its_max_speed_the_needle_stops_at_full_scale() {
        let context = speedContext(maxSpeed: 120)
        let dial = speedometer.layout(in: context).dial

        let bitmap = OverlayRenderFixture.render(speedometer, speed(150), context: context, parts: .dynamicOnly)

        #expect(needle(at: 1, in: bitmap, on: dial))
        #expect(speedometer.readouts(speed(150), context: context) == ["150"])
    }

    @Test func test_a_speed_gap_draws_no_needle() {
        let bitmap = OverlayRenderFixture.render(speedometer, speed(nil), context: speedContext(), parts: .dynamicOnly)

        #expect(bitmap.count(where: isNeedle) == 0)
    }

    // MARK: - The dial

    /// A dial is round and inside its widget, whatever the widget's shape.
    @Test(arguments: [CGSize(width: 240, height: 240), CGSize(width: 300, height: 180),
                      CGSize(width: 160, height: 260)])
    func test_a_dial_is_round_and_inside_the_widget(_ size: CGSize) {
        let context = OverlayRenderFixture.context(.rpm, rect: CGRect(origin: .zero, size: size), plate: .none,
                                                   options: OverlayWidgetOptions(gaugeStyle: .needle))
        let dial = tachometer.layout(in: context).dial

        let circle = CGRect(x: dial.centre.x - dial.radius, y: dial.centre.y - dial.radius,
                            width: 2 * dial.radius, height: 2 * dial.radius)
        #expect(context.content.contains(circle))
        #expect(dial.radius >= min(context.content.width, context.content.height) / 2 * 0.9)
    }

    /// The scale, its labels and caption are drawn once; only the needle and
    /// the digits move.
    @Test func test_the_face_is_static_and_the_needle_and_digits_dynamic() {
        let context = tachContext()
        let dial = tachometer.layout(in: context).dial

        let still = OverlayRenderFixture.render(tachometer, OverlayRenderFixture.midLap, context: context,
                                                parts: .staticOnly)
        let moving = OverlayRenderFixture.render(tachometer, OverlayRenderFixture.midLap, context: context,
                                                 parts: .dynamicOnly)

        for label in dial.labels {
            #expect(still.count(in: label.slot) { !$0.isTransparent } > 0, "label \(label.text)")
        }
        #expect(still.count(in: dial.caption) { !$0.isTransparent } > 0)
        #expect(still.count(in: dial.value) { !$0.isTransparent } == 0)
        #expect(moving.count(in: dial.value) { !$0.isTransparent } > 0)
        #expect(still.count(where: isNeedle) == 0)
    }

    /// No two texts of a dial overlap: tick labels, the digits and the caption.
    @Test(arguments: [16_000.0, 9_000, 30_000])
    func test_no_two_texts_of_a_dial_overlap(_ maxRPM: Double) {
        let dial = tachometer.layout(in: tachContext(maxRPM: maxRPM, shift: maxRPM * 0.9)).dial
        let slots = dial.labels.map(\.slot) + [dial.value, dial.caption]

        for (index, slot) in slots.enumerated() {
            for other in slots[(index + 1)...] {
                let shared = slot.intersection(other)
                #expect(shared.isNull || shared.width * shared.height < 1e-9, "\(slot) overlaps \(other)")
            }
        }
    }
}
