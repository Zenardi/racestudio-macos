import CoreGraphics
import Foundation

/// The G-ball (issues 9.11 and 9.18): a dot at the frame's `(lateral,
/// longitudinal)` G — lateral to the right, longitudinal up (accelerating up,
/// braking down) — scaled so the outer ring is ``OverlayWidgetOptions/gForceMax``
/// and held on it beyond, over rings at 0.5 g and 1 g, trailing the last second
/// of samples faded from newest to oldest.
///
/// Each ring carries its g on its top, right of the vertical axis — the outer
/// one with the unit — and a ring too close to the next for its label gives the
/// label up, innermost first. Under the ball, the combined G and its signed
/// lateral and longitudinal parts are written as numbers: the real values, even
/// while the dot is held on the outer ring. Without both axes there is no dot
/// and every number is `—`.
struct GForceWidget: OverlayWidgetDrawer {

    /// One ring's label: the ring's g, its text, and where it is written.
    struct RingLabel: Sendable {
        let g: Double
        let text: String
        let slot: CGRect
    }

    struct Layout: Sendable {
        /// The ball's centre — zero G.
        let centre: CGPoint
        /// The outer ring's radius — G max.
        let radius: CGFloat
        /// The dot's radius.
        let dot: CGFloat
        /// The rings' labels, outermost first: those that fit without overlapping.
        let ringLabels: [RingLabel]
        let ringLabelStyle: OverlayTextStyle
        /// Where the combined G goes, under the ball.
        let combined: CGRect
        let combinedStyle: OverlayTextStyle
        /// The lateral and longitudinal rows' label slots, in that order.
        let axisLabels: [CGRect]
        /// The lateral and longitudinal rows' value slots, in that order.
        let axisValues: [CGRect]
        let axisLabelStyle: OverlayTextStyle
        let axisValueStyle: OverlayTextStyle
    }

    /// The rings drawn inside the outer one, in g.
    static let rings = [0.5, 1.0]
    /// A ring label's height, as a share of the outer ring's radius.
    static let ringLabelHeight: CGFloat = 0.2

    /// The axis rows' labels, in the export language: lateral, longitudinal.
    static func labels(_ context: OverlayWidgetContext) -> [String] {
        [context.label(.overlayLabelLateral), context.label(.overlayLabelLongitudinal)]
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        // The numbers take the strip under a ball as wide as the widget — at
        // least a quarter of its height, at most two fifths.
        let strip = min(max(content.height - content.width, content.height * 0.25), content.height * 0.4).rounded()
        let (numbers, ballArea) = content.divided(atDistance: strip, from: .minYEdge)
        let radius = (min(ballArea.width, ballArea.height) / 2 * 0.88).rounded()
        let centre = CGPoint(x: ballArea.midX.rounded(), y: ballArea.midY.rounded())
        let labels = Self.ringLabels(centre: centre, radius: radius, context: context)
        let (axisRow, upper) = numbers.divided(atDistance: (numbers.height * 0.45).rounded(), from: .minYEdge)
        // Text is placed by its capitals, so the unit's `g` dips below them:
        // keep room for it clear of the axis row.
        let combined = upper.divided(atDistance: (upper.height * 0.2).rounded(), from: .minYEdge).remainder
        // Lateral on the left, longitudinal on the right, a gap between them so
        // a value never runs into the next label.
        let half = ((axisRow.width - (axisRow.width * 0.1).rounded()) / 2).rounded(.down)
        let rows = [axisRow.minX, axisRow.maxX - half].map { x in
            CGRect(x: x, y: axisRow.minY, width: half, height: axisRow.height)
                .divided(atDistance: (half * 0.4).rounded(), from: .minXEdge)
        }
        let widestLabel = labels.map(\.text).max { $0.count < $1.count } ?? ""
        let widestAxisLabel = Self.labels(context).max { $0.count < $1.count } ?? ""
        return Layout(centre: centre, radius: radius, dot: max(2, (radius * 0.09).rounded()), ringLabels: labels,
                      ringLabelStyle: context.style(for: labels.first?.slot ?? .zero, fitting: widestLabel),
                      combined: combined, combinedStyle: context.style(for: combined, fitting: "88.88 g"),
                      axisLabels: rows.map(\.slice), axisValues: rows.map(\.remainder),
                      axisLabelStyle: context.style(for: rows[0].slice, fitting: widestAxisLabel),
                      axisValueStyle: context.style(for: rows[0].remainder, fitting: "\u{2212}88.88"))
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
        for label in layout.ringLabels {
            context.draw(label.text, layout.ringLabelStyle, in: label.slot, alignment: .leading,
                         color: context.palette.secondary, in: graphics)
        }
        for (label, slot) in zip(Self.labels(context), layout.axisLabels) {
            context.draw(label, layout.axisLabelStyle, in: slot, alignment: .leading,
                         color: context.palette.secondary, in: graphics)
        }
    }

    /// The combined G with its unit, then the lateral and longitudinal G, signed.
    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        guard let ball = Self.ball(frame) else { return Array(repeating: OverlayFormatter.missing, count: 3) }
        let formatter = context.formatter
        let combined = formatter.number(hypot(ball.lateral, ball.longitudinal), decimals: 2)
        return [combined == OverlayFormatter.missing ? combined : combined + " g",
                formatter.signed(ball.lateral, decimals: 2), formatter.signed(ball.longitudinal, decimals: 2)]
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
        if let ball = Self.ball(frame) {
            let place = position(ball.lateral, ball.longitudinal, layout, maximum)
            graphics.setFillColor(context.palette.outline)
            graphics.fillEllipse(in: circle(place, layout.dot + context.outline))
            graphics.setFillColor(context.palette.accent)
            graphics.fillEllipse(in: circle(place, layout.dot))
        }
        let texts = readouts(frame, context: context)
        context.draw(texts[0], layout.combinedStyle, in: layout.combined, in: graphics)
        for (text, slot) in zip(texts.dropFirst(), layout.axisValues) {
            context.draw(text, layout.axisValueStyle, in: slot, alignment: .trailing, in: graphics)
        }
    }

    // MARK: - Internals

    /// The rings' labels, outermost first. The outer ring's always stays; an
    /// inner one stays when it is clear of the horizontal axis and of every
    /// label already kept.
    private static func ringLabels(centre: CGPoint, radius: CGFloat,
                                   context: OverlayWidgetContext) -> [RingLabel] {
        let maximum = context.options.gForceMax
        let height = max(radius * ringLabelHeight, 1)
        let gap = max(2 * context.outline, (radius * 0.05).rounded())
        let width = max(radius * 0.7, 1)
        var kept: [RingLabel] = []
        for g in [maximum] + rings.filter({ $0 < maximum }).reversed() {
            let ring = centre.y + CGFloat(g / maximum) * radius
            let slot = CGRect(x: centre.x + gap, y: ring - height / 2, width: width, height: height)
            let isOuter = kept.isEmpty
            let clear = slot.minY > centre.y + context.outline && kept.allSatisfy { !overlaps($0.slot, slot) }
            guard isOuter || clear else { continue }
            let text = ringText(g, formatter: context.formatter)
            kept.append(RingLabel(g: g, text: isOuter ? text + " g" : text, slot: slot))
        }
        return kept
    }

    /// `g` with as few decimals as it needs (at most two): `0.5`, `1`, `2.5`.
    private static func ringText(_ g: Double, formatter: OverlayFormatter) -> String {
        let decimals = (0...2).first { places in
            let scaled = g * pow(10, Double(places))
            return abs(scaled - scaled.rounded()) < 1e-9
        } ?? 2
        return formatter.number(g, decimals: decimals)
    }

    /// Whether two slots share any area — touching edges do not count.
    private static func overlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let shared = lhs.intersection(rhs)
        return !shared.isNull && shared.width * shared.height > 0
    }

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
