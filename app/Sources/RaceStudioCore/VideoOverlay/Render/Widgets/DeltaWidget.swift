import CoreGraphics
import Foundation

/// The delta bar (issue 9.11): the live delta to the reference lap as a bar
/// centred on zero — filled right in the loss colour while losing time (delta
/// > 0), left in the gain colour while gaining — reaching its end at
/// ± ``OverlayWidgetOptions/deltaRange`` and clamped beyond, with the signed
/// delta (`+0.23` / `−0.41`) above it in the same colour.
struct DeltaWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// Where the number goes.
        let value: CGRect
        /// The whole bar, ± range.
        let bar: CGRect
        /// The bar's zero, on a pixel boundary; each side fills to its own end.
        let centre: CGFloat
        let valueStyle: OverlayTextStyle
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let gap = max(1, (content.height * 0.08).rounded())
        let (value, rest) = content.divided(atDistance: (content.height * 0.58).rounded(), from: .maxYEdge)
        let bar = rest.divided(atDistance: gap, from: .maxYEdge).remainder.pixelAligned
        return Layout(value: value, bar: bar, centre: bar.minX + (bar.width / 2).rounded(.down),
                      valueStyle: context.style(for: value, fitting: "\u{2212}88.88"))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        graphics.setFillColor(context.palette.guide)
        graphics.fill(layout.bar.pixelAligned)
        let tick = max(2, (2 * context.scale).rounded())
        graphics.setFillColor(context.palette.text)
        graphics.fill(CGRect(x: layout.centre - tick / 2, y: layout.bar.minY, width: tick, height: layout.bar.height)
            .pixelAligned)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.delta(frame.delta)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        let text = readouts(frame, context: context)[0]
        let color = Self.color(of: text, palette: context.palette)
        // Filled only when the number is signed, so bar and number agree.
        if let delta = frame.delta, Self.isSigned(text) {
            let losing = delta > 0
            let span = losing ? layout.bar.maxX - layout.centre : layout.centre - layout.bar.minX
            let length = span * min(abs(delta) / max(context.options.deltaRange, 0.01), 1)
            graphics.setFillColor(losing ? context.palette.loss : context.palette.gain)
            graphics.fill(CGRect(x: losing ? layout.centre : layout.centre - length, y: layout.bar.minY,
                                 width: length, height: layout.bar.height).pixelAligned)
        }
        context.draw(text, layout.valueStyle, in: layout.value, color: color, in: graphics)
    }

    /// Whether a written delta carries a sign — it does not round to zero.
    private static func isSigned(_ text: String) -> Bool {
        text.hasPrefix("+") || text.hasPrefix("\u{2212}")
    }

    /// The colour a written delta takes: loss when it reads `+`, gain when it
    /// reads `−`, the readout colour when it rounds to zero.
    private static func color(of text: String, palette: OverlayPalette) -> CGColor {
        if text.hasPrefix("+") { return palette.loss }
        if text.hasPrefix("\u{2212}") { return palette.gain }
        return palette.text
    }
}
