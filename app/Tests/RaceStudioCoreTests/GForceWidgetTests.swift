import CoreGraphics
import Testing
@testable import RaceStudioCore

/// The G-ball (issue 9.11): lateral G to the right, longitudinal G up
/// (acceleration up, braking down), scaled so the outer ring is the widget's
/// G max, with rings at 0.5 g and 1 g and a fading one-second trail.
@Suite struct GForceWidgetTests {

    private let widget = GForceWidget()
    private let theme = OverlayTheme.raceStudio
    private let options = OverlayWidgetOptions(gForceMax: 2)

    private func context() -> OverlayWidgetContext {
        OverlayRenderFixture.context(.gForce, rect: CGRect(x: 0, y: 0, width: 220, height: 220), plate: .none,
                                     options: options)
    }

    /// Where `(lateral, longitudinal)` lands on the ball, by its definition.
    private func expected(_ lateral: Double, _ longitudinal: Double, _ layout: GForceWidget.Layout) -> CGPoint {
        CGPoint(x: layout.centre.x + lateral / 2 * layout.radius, y: layout.centre.y + longitudinal / 2 * layout.radius)
    }

    private func isDot(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.matches(theme.accent, tolerance: 8)
    }

    // MARK: - What it reads

    @Test func test_a_ball_with_both_axes_writes_nothing() {
        #expect(widget.readouts(OverlayRenderFixture.midLap, context: context()).isEmpty)
    }

    @Test func test_a_g_gap_reads_an_em_dash() {
        #expect(widget.readouts(OverlayRenderFixture.gap, context: context()) == ["—"])
    }

    @Test func test_one_missing_axis_reads_an_em_dash() {
        let frame = TelemetryFrame(time: 0, values: [.latG: 0.4])

        #expect(widget.readouts(frame, context: context()) == ["—"])
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

    @Test func test_a_gap_draws_no_dot() {
        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context(),
                                                 parts: .dynamicOnly)

        #expect(bitmap.count(where: isDot) == 0)
        #expect(bitmap.count { !$0.isTransparent } > 0)
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

    @Test func test_rings_mark_half_a_g_one_g_and_the_outer_scale() {
        let layout = widget.layout(in: context())

        let bitmap = OverlayRenderFixture.render(widget, OverlayRenderFixture.gap, context: context(),
                                                 parts: .staticOnly)

        for g in [0.5, 1.0, 2.0] {
            let radius = g / 2 * layout.radius
            let onRing = CGPoint(x: layout.centre.x + radius * 0.7071, y: layout.centre.y + radius * 0.7071)
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
