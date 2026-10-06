import CoreGraphics
import Foundation

/// The G-ball (issue 9.11): a dot at the frame's `(lateral, longitudinal)` G —
/// lateral to the right, longitudinal up (accelerating up, braking down) —
/// scaled so the outer ring is ``OverlayWidgetOptions/gForceMax`` and held on
/// it beyond, over rings at 0.5 g and 1 g, trailing the last second of samples
/// faded from newest to oldest. Without both axes the dot gives way to `—`.
struct GForceWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// The ball's centre — zero G.
        let centre: CGPoint
        /// The outer ring's radius — G max.
        let radius: CGFloat
        /// The dot's radius.
        let dot: CGFloat
        /// Where `—` goes.
        let missing: CGRect
        let missingStyle: OverlayTextStyle
    }

    /// The rings drawn inside the outer one, in g.
    static let rings = [0.5, 1.0]

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let radius = (min(content.width, content.height) / 2 * 0.88).rounded()
        let centre = CGPoint(x: content.midX.rounded(), y: content.midY.rounded())
        let missing = CGRect(x: centre.x - radius, y: centre.y - radius / 4, width: 2 * radius, height: radius / 2)
        return Layout(centre: centre, radius: radius, dot: max(2, (radius * 0.09).rounded()), missing: missing,
                      missingStyle: context.style(for: missing, fitting: OverlayFormatter.missing))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        let maximum = context.options.gForceMax
        graphics.setStrokeColor(context.palette.guide)
        graphics.setLineWidth(context.outline)
        for g in Self.rings where g < maximum {
            graphics.strokeEllipse(in: circle(layout.centre, CGFloat(g / maximum) * layout.radius))
        }
        graphics.strokeEllipse(in: circle(layout.centre, layout.radius))
        graphics.move(to: CGPoint(x: layout.centre.x - layout.radius, y: layout.centre.y))
        graphics.addLine(to: CGPoint(x: layout.centre.x + layout.radius, y: layout.centre.y))
        graphics.move(to: CGPoint(x: layout.centre.x, y: layout.centre.y - layout.radius))
        graphics.addLine(to: CGPoint(x: layout.centre.x, y: layout.centre.y + layout.radius))
        graphics.strokePath()
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        Self.ball(frame) == nil ? [OverlayFormatter.missing] : []
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        let maximum = context.options.gForceMax
        let trail = frame.gTrail
        for (index, point) in trail.enumerated() where point.lateral.isFinite && point.longitudinal.isFinite {
            // Newest (last) strongest, every point visible — faded in the colour,
            // so the widget's own opacity still applies on top.
            let fade = 0.15 + 0.6 * CGFloat(index + 1) / CGFloat(trail.count)
            graphics.setFillColor(context.palette.accent(alpha: fade))
            let place = position(point.lateral, point.longitudinal, layout, maximum)
            graphics.fillEllipse(in: circle(place, layout.dot * 0.55))
        }
        guard let ball = Self.ball(frame) else {
            for text in readouts(frame, context: context) {
                context.draw(text, layout.missingStyle, in: layout.missing, in: graphics)
            }
            return
        }
        let place = position(ball.lateral, ball.longitudinal, layout, maximum)
        graphics.setFillColor(context.palette.outline)
        graphics.fillEllipse(in: circle(place, layout.dot + context.outline))
        graphics.setFillColor(context.palette.accent)
        graphics.fillEllipse(in: circle(place, layout.dot))
    }

    // MARK: - Internals

    /// The frame's G, when it has both axes.
    private static func ball(_ frame: TelemetryFrame) -> (lateral: Double, longitudinal: Double)? {
        guard let lateral = frame.latG, let longitudinal = frame.lonG, lateral.isFinite, longitudinal.isFinite
        else { return nil }
        return (lateral, longitudinal)
    }

    /// Where `(lateral, longitudinal)` G lands, held inside the outer ring.
    private func position(_ lateral: Double, _ longitudinal: Double, _ layout: Layout, _ maximum: Double) -> CGPoint {
        var dx = CGFloat(lateral / maximum) * layout.radius
        var dy = CGFloat(longitudinal / maximum) * layout.radius
        let length = hypot(dx, dy)
        if length > layout.radius {
            dx *= layout.radius / length
            dy *= layout.radius / length
        }
        return CGPoint(x: layout.centre.x + dx, y: layout.centre.y + dy)
    }

    private func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
    }
}
