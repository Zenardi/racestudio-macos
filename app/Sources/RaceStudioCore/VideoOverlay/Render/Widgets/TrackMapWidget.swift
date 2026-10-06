import CoreGraphics
import Foundation

/// The mini track map (issue 9.11): the session's racing line fitted into the
/// widget — north up, turned clockwise by ``OverlayWidgetOptions/trackMapRotation``
/// — with the start and the sector boundaries marked, and the kart's position
/// dot held inside the widget. Without a GPS fix the dot gives way to `—`.
struct TrackMapWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// Where the map is fitted.
        let area: CGRect
        /// Unit map frame → drawing space.
        let projection: Projection
        /// The racing line's width.
        let line: CGFloat
        /// The position dot's radius.
        let dot: CGFloat
        let missingStyle: OverlayTextStyle
    }

    /// The unit map frame (north up, `y` southwards) turned and fitted into the
    /// widget, in drawing space (`y` up).
    struct Projection: Sendable {
        let cosine: CGFloat
        let sine: CGFloat
        /// The middle of the turned map's bounds.
        let middle: CGPoint
        let scale: CGFloat
        /// Where that middle lands.
        let target: CGPoint

        /// Fit `points` (the unit square when there are none), turned
        /// `degrees` clockwise about the frame's centre, into `area`.
        init(fitting points: [CGPoint], turnedBy degrees: Double, into area: CGRect) {
            let radians = degrees * .pi / 180
            let cosine = CGFloat(cos(radians)), sine = CGFloat(sin(radians))
            self.cosine = cosine
            self.sine = sine
            target = CGPoint(x: area.midX, y: area.midY)
            let frame = points.isEmpty
                ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                : points
            let turned = frame.map { Self.turn($0, cosine: cosine, sine: sine) }
            let bounds = turned.dropFirst().reduce(CGRect(origin: turned[0], size: .zero)) { box, point in
                box.union(CGRect(origin: point, size: .zero))
            }
            middle = CGPoint(x: bounds.midX, y: bounds.midY)
            // A line with no extent (one point) is drawn at the frame's scale.
            scale = max(bounds.width, bounds.height) > 1e-9
                ? min(area.width / max(bounds.width, 1e-9), area.height / max(bounds.height, 1e-9))
                : min(area.width, area.height)
        }

        /// Where unit-frame `point` lands.
        func place(_ point: CGPoint) -> CGPoint {
            let turned = Self.turn(point, cosine: cosine, sine: sine)
            return CGPoint(x: target.x + (turned.x - middle.x) * scale, y: target.y - (turned.y - middle.y) * scale)
        }

        /// `point` turned about the frame's centre; with `y` growing southwards
        /// a positive angle turns clockwise as seen.
        private static func turn(_ point: CGPoint, cosine: CGFloat, sine: CGFloat) -> CGPoint {
            let dx = point.x - 0.5, dy = point.y - 0.5
            return CGPoint(x: 0.5 + dx * cosine - dy * sine, y: 0.5 + dx * sine + dy * cosine)
        }
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let dot = max(3, (min(content.width, content.height) * 0.05).rounded())
        let area = content.insetBy(dx: dot + context.outline, dy: dot + context.outline)
        let missing = CGRect(x: content.minX, y: content.midY - content.height * 0.15, width: content.width,
                             height: content.height * 0.3)
        return Layout(area: area,
                      projection: Projection(fitting: context.track.racingLine,
                                             turnedBy: context.options.trackMapRotation, into: area),
                      line: max(1.5, 2.5 * context.scale), dot: dot,
                      missingStyle: context.style(for: missing, fitting: OverlayFormatter.missing))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        let points = context.track.racingLine.map(layout.projection.place)
        if let first = points.first {
            let path = CGMutablePath()
            path.addLines(between: points)
            graphics.setLineJoin(.round)
            graphics.setLineCap(.round)
            stroke(path, width: layout.line + 2 * context.outline, color: context.palette.outline, in: graphics)
            stroke(path, width: layout.line, color: context.palette.text, in: graphics)
            mark(first, radius: layout.line * 1.6, color: context.palette.text, context: context, in: graphics)
        }
        for tick in context.track.sectorTicks.map(layout.projection.place) {
            mark(tick, radius: layout.line * 1.4, color: context.palette.secondary, context: context, in: graphics)
        }
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        frame.position == nil ? [OverlayFormatter.missing] : []
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        guard let position = frame.position, position.point.x.isFinite, position.point.y.isFinite else {
            for text in readouts(frame, context: context) {
                let slot = CGRect(x: context.content.minX, y: layout.area.midY - layout.area.height * 0.15,
                                  width: context.content.width, height: layout.area.height * 0.3)
                context.draw(text, layout.missingStyle, in: slot, in: graphics)
            }
            return
        }
        let placed = layout.projection.place(position.point)
        let held = CGPoint(x: min(max(placed.x, layout.area.minX), layout.area.maxX),
                           y: min(max(placed.y, layout.area.minY), layout.area.maxY))
        mark(held, radius: layout.dot, color: context.palette.accent, context: context, in: graphics)
    }

    // MARK: - Internals

    private func stroke(_ path: CGPath, width: CGFloat, color: CGColor, in graphics: CGContext) {
        graphics.addPath(path)
        graphics.setLineWidth(width)
        graphics.setStrokeColor(color)
        graphics.strokePath()
    }

    /// A dot of `color` at `centre`, ringed by the dark outline.
    private func mark(_ centre: CGPoint, radius: CGFloat, color: CGColor, context: OverlayWidgetContext,
                      in graphics: CGContext) {
        let outer = radius + context.outline
        graphics.setFillColor(context.palette.outline)
        graphics.fillEllipse(in: CGRect(x: centre.x - outer, y: centre.y - outer, width: 2 * outer, height: 2 * outer))
        graphics.setFillColor(color)
        graphics.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius,
                                        height: 2 * radius))
    }
}
