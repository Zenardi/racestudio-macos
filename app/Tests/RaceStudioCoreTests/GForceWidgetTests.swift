import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The G-ball (issues 9.11 and 9.18): lateral G to the right, longitudinal G up
/// (acceleration up, braking down), scaled so the outer ring is the widget's
/// G max, with rings at 0.5 g and 1 g labelled with their g, a fading
/// one-second trail, and under the ball the combined G and its lateral and
/// longitudinal parts as numbers.
@Suite struct GForceWidgetTests {

    private let widget = GForceWidget()
    private let theme = OverlayTheme.raceStudio
    private let brazilian = OverlayFormatter(locale: Locale(identifier: "pt_BR"))

    /// A G-ball of `width` × `height` pixels with no plate, at G max `max`.
    private func context(width: CGFloat = 220, height: CGFloat = 220, max: Double = 2,
                         formatter: OverlayFormatter = OverlayFormatter()) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.gForce, rect: CGRect(x: 0, y: 0, width: width, height: height), plate: .none,
                                     options: OverlayWidgetOptions(gForceMax: max), formatter: formatter)
    }

    /// Where `(lateral, longitudinal)` lands on a ball of G max 2, by its definition.
    private func expected(_ lateral: Double, _ longitudinal: Double, _ layout: GForceWidget.Layout) -> CGPoint {
        CGPoint(x: layout.centre.x + lateral / 2 * layout.radius, y: layout.centre.y + longitudinal / 2 * layout.radius)
    }

    private func isDot(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.matches(theme.accent, tolerance: 8)
    }

    /// Every text slot of `layout`: the ring labels, the combined G, and each
    /// axis row's label and value.
    private func textSlots(_ layout: GForceWidget.Layout) -> [CGRect] {
        layout.ringLabels.map(\.slot) + [layout.combined] + layout.axisLabels + layout.axisValues
    }

    // MARK: - What it reads

    /// The combined G to the hundredth with its unit, then the lateral and
    /// longitudinal G, always signed.
    @Test func test_a_ball_reads_its_combined_lateral_and_longitudinal_g() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 0.5, .lonG: -0.8])

        #expect(widget.readouts(frame, context: context()) == ["0.94 g", "+0.50", "\u{2212}0.80"])
    }

    /// Past the outer ring the dot is held on it, but the numbers say the real G.
    @Test func test_g_beyond_the_outer_ring_reads_its_real_value() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 2.63, .lonG: 0])

        #expect(widget.readouts(frame, context: context(max: 2)) == ["2.63 g", "+2.63", "0.00"])
    }

    /// A value no kart can pull (a corrupt file) reads `—`, never a number or
    /// a bare unit.
    @Test func test_an_absurd_g_reads_an_em_dash() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 1e13, .lonG: 0])

        #expect(widget.readouts(frame, context: context()) == ["—", "—", "0.00"])
    }

    @Test func test_a_g_gap_reads_em_dashes() {
        #expect(widget.readouts(OverlayRenderFixture.gap, context: context()) == ["—", "—", "—"])
    }

    @Test func test_one_missing_axis_reads_em_dashes() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 0.4])

        #expect(widget.readouts(frame, context: context()) == ["—", "—", "—"])
    }

    @Test func test_the_readouts_write_the_export_decimal_mark() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 0.5, .lonG: -0.8])

        #expect(widget.readouts(frame, context: context(formatter: brazilian)) == ["0,94 g", "+0,50", "\u{2212}0,80"])
    }

    @Test func test_the_axis_labels_follow_the_export_language() {
        #expect(GForceWidget.labels(context()) == ["LAT", "LON"])
        #expect(GForceWidget.labels(context(formatter: brazilian)) == ["LAT", "LONG"])
    }

    // MARK: - Ring labels

    /// Every ring drawn carries its g, outermost first; only the outer one
    /// carries the unit.
    @Test(arguments: [RingCase(max: 2, labels: ["2 g", "1", "0.5"]), RingCase(max: 3, labels: ["3 g", "1"]),
                      RingCase(max: 1.5, labels: ["1.5 g", "1", "0.5"]), RingCase(max: 1, labels: ["1 g", "0.5"]),
                      RingCase(max: 0.8, labels: ["0.8 g", "0.5"])])
    func test_each_ring_is_labelled_with_its_g(_ ring: RingCase) {
        let layout = widget.layout(in: context(height: 300, max: ring.max))

        #expect(layout.ringLabels.map(\.text) == ring.labels, "G max \(ring.max)")
    }

    /// A G max set by hand with more decimals is marked with two.
    @Test func test_a_ring_label_has_at_most_two_decimals() {
        let layout = widget.layout(in: context(height: 300, max: 1.234))

        #expect(layout.ringLabels.first?.text == "1.23 g")
    }

    @Test func test_ring_labels_write_the_export_decimal_mark() {
        let layout = widget.layout(in: context(height: 300, max: 1.5, formatter: brazilian))

        #expect(layout.ringLabels.map(\.text) == ["1,5 g", "1", "0,5"])
    }

    /// A label sits on its ring at the top, right of the vertical axis and
    /// above the horizontal one, so it crosses neither.
    @Test func test_a_ring_label_sits_on_its_ring_clear_of_the_axes() {
        let context = context(height: 300)
        let layout = widget.layout(in: context)

        for label in layout.ringLabels {
            let ring = layout.centre.y + CGFloat(label.g / 2) * layout.radius
            #expect(label.slot.minY < ring && ring < label.slot.maxY, "\(label.text) is not on its ring")
            #expect(label.slot.minX > layout.centre.x + context.outline, "\(label.text) crosses the vertical axis")
            #expect(label.slot.minY > layout.centre.y + context.outline, "\(label.text) crosses the horizontal axis")
            #expect(context.content.contains(label.slot), "\(label.text) leaves the widget")
        }
    }

    /// Rings too close for their labels drop the inner labels first: at 5 g
    /// the 0.5 g ring sits too near the 1 g one.
    @Test func test_labels_that_would_collide_drop_the_innermost_first() {
        let layout = widget.layout(in: context(height: 300, max: 5))

        #expect(layout.ringLabels.map(\.text) == ["5 g", "1"])
    }

    /// The labels never change: they are drawn once, with the rings.
    @Test func test_ring_labels_are_drawn_in_the_static_layer() {
        let context = context(height: 300)
        let layout = widget.layout(in: context)
        let lowerLeft = TelemetryFrame(time: 0, values: [.latG: -1.5, .lonG: -1.5])

        let still = OverlayRenderFixture.render(widget, lowerLeft, context: context, parts: .staticOnly)
        let moving = OverlayRenderFixture.render(widget, lowerLeft, context: context, parts: .dynamicOnly)

        for label in layout.ringLabels {
            #expect(still.count(in: label.slot) { !$0.isTransparent } > 0, "\(label.text) is not drawn")
            #expect(moving.count(in: label.slot) { !$0.isTransparent } == 0, "\(label.text) is redrawn every frame")
        }
    }

    // MARK: - The numbers

    /// The numbers sit under the ball: the combined G, then the lateral and
    /// longitudinal rows.
    @Test func test_the_numbers_sit_under_the_ball() {
        let context = context(width: 154, height: 202)
        let layout = widget.layout(in: context)

        #expect(layout.combined.maxY <= layout.centre.y - layout.radius)
        #expect(layout.axisValues.allSatisfy { $0.maxY <= layout.combined.minY })
        #expect(context.content.contains(layout.combined))
        #expect(layout.axisLabels.count == 2 && layout.axisValues.count == 2)
    }

    /// A crash spike reads two whole digits of G; even those fit their slots.
    @Test func test_a_two_digit_g_still_fits_its_slots() {
        let context = context(width: 179, height: 223)
        let layout = widget.layout(in: context)

        #expect(layout.combinedStyle.width(of: "23.45 g") <= layout.combined.width - 2 * context.outline)
        #expect(layout.axisValueStyle.width(of: "\u{2212}23.45") <= layout.axisValues[0].width - 2 * context.outline)
    }

    /// The lateral and longitudinal halves keep a clear gap, so a value never
    /// runs into the next label.
    @Test func test_the_lateral_and_longitudinal_halves_keep_apart() {
        let layout = widget.layout(in: context(width: 179, height: 223))

        #expect(layout.axisLabels[1].minX - layout.axisValues[0].maxX >= layout.combined.width * 0.06)
    }

    /// The readouts move every frame; their labels do not.
    @Test func test_the_numbers_are_drawn_each_frame_and_their_labels_once() {
        let context = context(width: 154, height: 202)
        let layout = widget.layout(in: context)

        let still = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context,
                                                parts: .staticOnly)
        let moving = OverlayRenderFixture.render(widget, OverlayRenderFixture.midLap, context: context,
                                                 parts: .dynamicOnly)

        #expect(moving.count(in: layout.combined) { !$0.isTransparent } > 0)
        #expect(still.count(in: layout.combined) { !$0.isTransparent } == 0)
        for (label, value) in zip(layout.axisLabels, layout.axisValues) {
            #expect(still.count(in: label) { !$0.isTransparent } > 0)
            #expect(moving.count(in: value) { !$0.isTransparent } > 0)
            #expect(moving.count(in: label) { !$0.isTransparent } == 0)
        }
    }

    /// At any size and scale no two texts overlap, and none overlaps the
    /// numbers' place under the ball.
    @Test(arguments: [CGSize(width: 34, height: 18), CGSize(width: 60, height: 80), CGSize(width: 154, height: 202),
                      CGSize(width: 220, height: 220), CGSize(width: 300, height: 160)], [0.5, 2.0, 5.0])
    func test_no_two_texts_overlap(_ size: CGSize, _ max: Double) {
        let layout = widget.layout(in: context(width: size.width, height: size.height, max: max))
        let slots = textSlots(layout)

        for (index, slot) in slots.enumerated() {
            for other in slots[(index + 1)...] {
                let shared = slot.intersection(other)
                #expect(shared.isNull || shared.width * shared.height < 1e-9,
                        "\(slot) overlaps \(other) at \(size), \(max) g")
            }
        }
    }

    /// However small the widget, the outer ring's label and the combined G stay.
    @Test(arguments: [CGSize(width: 38, height: 22), CGSize(width: 22, height: 38), CGSize(width: 60, height: 60)])
    func test_the_outer_label_and_the_combined_g_stay_at_small_sizes(_ size: CGSize) {
        let layout = widget.layout(in: context(width: size.width, height: size.height))

        #expect(layout.ringLabels.first?.text == "2 g")
        #expect(layout.combined.width > 0 && layout.combined.height > 0)
    }

    // MARK: - The dot

    @Test func test_the_dot_sits_where_its_g_puts_it() throws {
        let layout = widget.layout(in: context())
        let frame = TelemetryFrame(time: 0, values: [.latG: 0.5, .lonG: -0.8])

        let bitmap = OverlayRenderFixture.render(widget, frame, context: context(), parts: .dynamicOnly)

        let dot = try #require(bitmap.centroid(where: isDot))
        #expect(dot.distance(to: expected(0.5, -0.8, layout)) <= 2)
    }

    @Test func test_a_dot_beyond_the_outer_ring_is_held_on_it() throws {
        let layout = widget.layout(in: context())
        let frame = TelemetryFrame(time: 0, values: [.latG: 3, .lonG: 0])

        let bitmap = OverlayRenderFixture.render(widget, frame, context: context(), parts: .dynamicOnly)

        let dot = try #require(bitmap.centroid(where: isDot))
        #expect(dot.distance(to: CGPoint(x: layout.centre.x + layout.radius, y: layout.centre.y)) <= 2)
    }

    /// Without both axes there is no dot; the numbers say `—`.
    @Test func test_a_gap_draws_no_dot() {
        let layout = widget.layout(in: context())

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context(),
                                                 parts: .dynamicOnly)

        #expect(bitmap.count(where: isDot) == 0)
        #expect(bitmap.count(in: layout.combined) { !$0.isTransparent } > 0)
    }

    // MARK: - The trail

    @Test func test_the_trail_fades_from_newest_to_oldest() {
        let layout = widget.layout(in: context())
        let laterals = [-0.8, -0.4, 0, 0.4, 0.8]
        let trail = laterals.enumerated().map { GForcePoint(time: Double($0.offset) * 0.2, lateral: $0.element,
                                                            longitudinal: 0.6) }
        let frame = TelemetryFrame(time: 1, values: [.latG: 0, .lonG: -1], gTrail: trail)

        let bitmap = OverlayRenderFixture.render(widget, frame, context: context(), parts: .dynamicOnly)

        let alphas = laterals.map { Int(bitmap.pixel(at: expected($0, 0.6, layout)).alpha) }
        #expect(alphas.allSatisfy { $0 > 0 })
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: - Guides

    /// Rings at 0.5 g, 1 g and the outer scale, probed on the lower-left
    /// diagonal, clear of the labels.
    @Test func test_rings_mark_half_a_g_one_g_and_the_outer_scale() {
        let layout = widget.layout(in: context())

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context(),
                                                 parts: .staticOnly)

        for g in [0.5, 1.0, 2.0] {
            let radius = g / 2 * layout.radius
            let onRing = CGPoint(x: layout.centre.x - radius * 0.7071, y: layout.centre.y - radius * 0.7071)
            let near = CGRect(x: onRing.x - 1.5, y: onRing.y - 1.5, width: 3, height: 3)
            #expect(bitmap.count(in: near) { !$0.isTransparent } > 0, "no ring at \(g) g")
        }
    }

    @Test func test_the_ball_fits_inside_the_widget() {
        let context = context()

        let layout = widget.layout(in: context)

        let ball = CGRect(x: layout.centre.x - layout.radius, y: layout.centre.y - layout.radius,
                          width: 2 * layout.radius, height: 2 * layout.radius)
        #expect(context.content.contains(ball))
    }
}

/// A G max and the ring labels it should give, outermost first.
struct RingCase: Sendable, CustomTestStringConvertible {
    let max: Double
    let labels: [String]

    var testDescription: String { "\(max) g" }
}
