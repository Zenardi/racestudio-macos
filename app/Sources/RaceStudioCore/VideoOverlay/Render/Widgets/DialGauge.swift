import CoreGraphics
import Foundation

/// A needle dial's scale (issue 9.15): from zero to ``maximum``, major ticks
/// every ``step`` — the smallest 1, 2 or 5 × 10ⁿ that cuts it into at most ten
/// parts, so the labels stay few and round.
struct DialScale: Equatable, Sendable {
    let maximum: Double
    let step: Double

    init(maximum: Double) {
        self.maximum = maximum
        self.step = Self.step(for: maximum)
    }

    /// The major ticks' values, from zero up to ``maximum``.
    var values: [Double] {
        guard maximum.isFinite, maximum > 0 else { return [0] }
        let count = Int((maximum / step + 1e-9).rounded(.down))
        return (0...count).map { Double($0) * step }
    }

    private static func step(for maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        let base = pow(10, log10(maximum / 10).rounded(.down))
        return [1.0, 2, 5, 10].map { $0 * base }.first { maximum / $0 <= 10 + 1e-9 } ?? 10 * base
    }
}

/// One label of a dial's scale: its text and where it is written.
struct DialLabel: Sendable {
    let text: String
    let slot: CGRect
}

/// Where a needle dial's parts sit in its widget (issue 9.15).
struct DialLayout: Sendable {
    /// The dial's centre — the needle's pivot.
    let centre: CGPoint
    /// The scale's outer radius.
    let radius: CGFloat
    /// The major ticks' places on the scale, `0…1`.
    let majors: [Double]
    /// The minor ticks' places, halfway between majors.
    let minors: [Double]
    /// The major ticks' labels, in scale order.
    let labels: [DialLabel]
    let labelStyle: OverlayTextStyle
    /// Where the digits go, in the dial's open bottom.
    let value: CGRect
    let valueStyle: OverlayTextStyle
    /// Where the caption — the unit — goes, under the digits.
    let caption: CGRect
    let captionStyle: OverlayTextStyle
}

/// The needle dials' shared geometry and drawing (issue 9.15): a 240° scale
/// running clockwise from lower left (210°) over the top (90°) to lower right
/// (−30°), the bottom left open for the digits and the caption. Angles are in
/// drawing space (counter-clockwise from +x, `y` up).
enum Dial {
    /// Where the scale starts: lower left.
    static let start = 210 * Double.pi / 180
    /// How far it sweeps, clockwise.
    static let sweep = 240 * Double.pi / 180

    /// The angle of `fraction` of the scale, held to the scale.
    static func angle(fraction: Double) -> CGFloat {
        CGFloat(start - sweep * min(max(fraction.isFinite ? fraction : 0, 0), 1))
    }

    /// A dial laid out in `context`'s content: the largest circle that fits,
    /// its major ticks labelled by `label`, and room in its open bottom for
    /// digits as wide as `valueTemplate` over `caption`.
    ///
    /// Past a 100 % text size (issue 9.21) every text's slot grows with it, and
    /// each text then keeps the largest size — never below its 100 % one — at
    /// which it clears the rest: the scale numbers stay inside the ticks and
    /// clear of each other; the readout stays clear of the numbers and under
    /// the needle's tail, which points straight down into it at mid-scale; the
    /// caption clears both; all of them stay in the widget.
    static func layout(in context: OverlayWidgetContext, scale: DialScale, label: (Double) -> String,
                       caption: String, valueTemplate: String) -> DialLayout {
        let content = context.content
        let radius = (min(content.width, content.height) / 2 * 0.95).rounded(.down)
        let centre = CGPoint(x: content.midX.rounded(), y: content.midY.rounded())
        let majors = scale.values.map { $0 / scale.maximum }
        var minors = zip(majors, majors.dropFirst()).map { ($0 + $1) / 2 }
        if let last = scale.values.last, last + scale.step / 2 <= scale.maximum {
            minors.append((last + scale.step / 2) / scale.maximum)
        }
        let grow = max(context.textSize, 1)
        let base = CGSize(width: radius * 0.24, height: radius * 0.13)
        let size = CGSize(width: base.width * grow, height: base.height * grow)
        let labels = zip(scale.values, majors).map { value, fraction -> DialLabel in
            let place = point(fraction, 0.68, centre: centre, radius: radius)
            return DialLabel(text: label(value), slot: CGRect(x: place.x - size.width / 2, y: place.y - size.height / 2,
                                                              width: size.width, height: size.height))
        }
        let valueBase = CGRect(x: centre.x - radius * 0.4, y: centre.y - radius * 0.58, width: radius * 0.8,
                               height: radius * 0.26)
        let captionBase = CGRect(x: centre.x - radius * 0.45, y: centre.y - radius * 0.86, width: radius * 0.9,
                                 height: radius * 0.15)
        let value = scaled(valueBase, by: grow), captionSlot = scaled(captionBase, by: grow)
        let widest = labels.map(\.text).max { $0.count < $1.count } ?? ""
        var labelStyle = context.style(for: CGRect(origin: .zero, size: base), fitting: widest, room: size)
        var valueStyle = context.style(for: valueBase, fitting: valueTemplate, room: value.size)
        var captionStyle = context.style(for: captionBase, fitting: caption, room: captionSlot.size)
        if grow > 1 {
            let ticks = radius * 0.86
            let tail = centre.y - radius * 0.12 - needleWidth(radius: radius) / 2 - context.outline
            let unsized = { (slot: CGRect, template: String) in
                context.style(for: slot, fitting: template, textSize: 1).capHeight
            }
            labelStyle = largest(labelStyle, floor: unsized(CGRect(origin: .zero, size: base), widest)) { style in
                let boxes = labels.map { style.box(of: $0.text, centredIn: $0.slot) }
                return boxes.allSatisfy { content.contains($0) && farthest($0, from: centre) <= ticks }
                    && zip(boxes, boxes.dropFirst()).allSatisfy { !overlaps($0, $1) }
            }
            let labelBoxes = labels.map { labelStyle.box(of: $0.text, centredIn: $0.slot) }
            valueStyle = largest(valueStyle, floor: unsized(valueBase, valueTemplate)) { style in
                let box = style.box(of: valueTemplate, centredIn: value)
                return content.contains(box) && box.maxY <= tail && labelBoxes.allSatisfy { !overlaps($0, box) }
            }
            let valueBox = valueStyle.box(of: valueTemplate, centredIn: value)
            captionStyle = largest(captionStyle, floor: unsized(captionBase, caption)) { style in
                let box = style.box(of: caption, centredIn: captionSlot)
                return content.contains(box) && !overlaps(box, valueBox) && labelBoxes.allSatisfy { !overlaps($0, box) }
            }
        }
        return DialLayout(centre: centre, radius: radius, majors: majors, minors: minors, labels: labels,
                          labelStyle: labelStyle, value: value, valueStyle: valueStyle,
                          caption: captionSlot, captionStyle: captionStyle)
    }

    /// The needle's width on a dial of `radius`.
    static func needleWidth(radius: CGFloat) -> CGFloat {
        max(2, (radius * 0.035).rounded())
    }

    /// Draw `dial`'s face: the scale's guide arc, a red zone over `redZone`
    /// (fractions of the scale), the ticks, their labels and `caption`.
    static func drawFace(_ dial: DialLayout, caption: String, redZone: ClosedRange<Double>?, in graphics: CGContext,
                         context: OverlayWidgetContext) {
        let palette = context.palette
        graphics.saveGState()
        graphics.setStrokeColor(palette.guide)
        graphics.setLineWidth(context.outline)
        stroke(arcOf: dial, radius: dial.radius, over: 0...1, in: graphics)
        if let zone = redZone, zone.upperBound > zone.lowerBound {
            graphics.setStrokeColor(palette.loss)
            graphics.setLineWidth(dial.radius * 0.10)
            stroke(arcOf: dial, radius: dial.radius * 0.93, over: zone, in: graphics)
        }
        graphics.setStrokeColor(palette.guide)
        graphics.setLineWidth(context.outline)
        stroke(ticks: dial.minors, of: dial, from: 0.93, in: graphics)
        graphics.setStrokeColor(palette.text)
        graphics.setLineWidth(max(context.outline * 1.5, dial.radius * 0.02))
        stroke(ticks: dial.majors, of: dial, from: 0.86, in: graphics)
        graphics.restoreGState()
        for label in dial.labels {
            context.draw(label.text, dial.labelStyle, in: label.slot, in: graphics)
        }
        context.draw(caption, dial.captionStyle, in: dial.caption, color: palette.secondary, in: graphics)
    }

    /// Draw the needle at `fraction` of `dial`'s scale — held to the scale —
    /// over a dark outline, with its hub.
    static func drawNeedle(at fraction: Double, on dial: DialLayout, in graphics: CGContext,
                           context: OverlayWidgetContext) {
        let angle = angle(fraction: fraction)
        let tip = point(atAngle: angle, 0.80, centre: dial.centre, radius: dial.radius)
        let tail = point(atAngle: angle + .pi, 0.12, centre: dial.centre, radius: dial.radius)
        let width = needleWidth(radius: dial.radius)
        graphics.saveGState()
        graphics.setLineCap(.round)
        for (colour, lineWidth) in [(context.palette.outline, width + 2 * context.outline),
                                    (context.palette.accent, width)] {
            graphics.move(to: tail)
            graphics.addLine(to: tip)
            graphics.setStrokeColor(colour)
            graphics.setLineWidth(lineWidth)
            graphics.strokePath()
        }
        let hub = dial.radius * 0.06
        graphics.setFillColor(context.palette.outline)
        graphics.fillEllipse(in: circle(dial.centre, hub + context.outline))
        graphics.setFillColor(context.palette.text)
        graphics.fillEllipse(in: circle(dial.centre, hub))
        graphics.restoreGState()
    }

    /// Write `text` — the dial's reading — in its digits' place.
    static func drawValue(_ text: String, on dial: DialLayout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.draw(text, dial.valueStyle, in: dial.value, in: graphics)
    }

    // MARK: - Internals

    /// `style` shrunk 5 % at a time until `fits` holds, but never below
    /// `floor` — its capitals at 100 %.
    private static func largest(_ style: OverlayTextStyle, floor: CGFloat,
                                where fits: (OverlayTextStyle) -> Bool) -> OverlayTextStyle {
        var style = style
        while !fits(style), style.capHeight > floor {
            style = OverlayTextStyle(capHeight: max(style.capHeight * 0.95, floor), outline: style.outline)
        }
        return style
    }

    /// `rect` scaled by `factor` about its centre — `rect` itself at `1`.
    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        guard factor != 1 else { return rect }
        return rect.insetBy(dx: -rect.width * (factor - 1) / 2, dy: -rect.height * (factor - 1) / 2)
    }

    /// How far `box`'s farthest corner is from `centre`.
    private static func farthest(_ box: CGRect, from centre: CGPoint) -> CGFloat {
        hypot(max(abs(box.minX - centre.x), abs(box.maxX - centre.x)),
              max(abs(box.minY - centre.y), abs(box.maxY - centre.y)))
    }

    /// Whether two boxes share any area — touching edges do not count.
    private static func overlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let shared = lhs.intersection(rhs)
        return !shared.isNull && shared.width * shared.height > 1e-9
    }

    /// The point `share` of `radius` out from `centre` at `fraction` of the scale.
    private static func point(_ fraction: Double, _ share: CGFloat, centre: CGPoint, radius: CGFloat) -> CGPoint {
        point(atAngle: angle(fraction: fraction), share, centre: centre, radius: radius)
    }

    /// The point `share` of `radius` out from `centre` at `angle`.
    private static func point(atAngle angle: CGFloat, _ share: CGFloat, centre: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + cos(angle) * radius * share, y: centre.y + sin(angle) * radius * share)
    }

    private static func stroke(arcOf dial: DialLayout, radius: CGFloat, over span: ClosedRange<Double>,
                               in graphics: CGContext) {
        graphics.addArc(center: dial.centre, radius: radius, startAngle: angle(fraction: span.lowerBound),
                        endAngle: angle(fraction: span.upperBound), clockwise: true)
        graphics.strokePath()
    }

    private static func stroke(ticks: [Double], of dial: DialLayout, from inner: CGFloat, in graphics: CGContext) {
        for fraction in ticks {
            graphics.move(to: point(fraction, inner, centre: dial.centre, radius: dial.radius))
            graphics.addLine(to: point(fraction, 1, centre: dial.centre, radius: dial.radius))
        }
        graphics.strokePath()
    }

    private static func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
    }
}
