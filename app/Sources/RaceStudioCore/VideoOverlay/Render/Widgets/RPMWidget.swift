import CoreGraphics
import Foundation

/// The RPM readout (issue 9.11): the engine speed in digits over a bar filled
/// to ``OverlayWidgetOptions/maxRPM``, with a shift light at the bar's end that
/// is lit at or above ``OverlayWidgetOptions/shiftLightRPM``.
struct RPMWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// Where the digits go.
        let value: CGRect
        /// Where the `RPM` label goes.
        let label: CGRect
        /// The bar at full scale.
        let bar: CGRect
        /// The shift light.
        let shiftLight: CGRect
        let valueStyle: OverlayTextStyle
        let labelStyle: OverlayTextStyle
    }

    /// The label beside the digits — the unit, the same in every language.
    static let label = "RPM"

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let gap = max(1, (content.height * 0.1).rounded())
        let (textRow, rest) = content.divided(atDistance: (content.height * 0.5).rounded(), from: .maxYEdge)
        let barRow = rest.divided(atDistance: gap, from: .maxYEdge).remainder
        let shiftLight = CGRect(x: barRow.maxX - barRow.height, y: barRow.minY, width: barRow.height,
                                height: barRow.height)
        let bar = CGRect(x: barRow.minX, y: barRow.minY, width: max(barRow.width - barRow.height - gap, 0),
                         height: barRow.height)
        let (value, label) = textRow.divided(atDistance: (textRow.width * 0.65).rounded(), from: .minXEdge)
        return Layout(value: value, label: label, bar: bar, shiftLight: shiftLight,
                      valueStyle: context.style(for: value, fitting: "88888"),
                      labelStyle: context.style(for: label, fitting: Self.label))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(Self.label, layout.labelStyle, in: layout.label, alignment: .trailing,
                     color: context.palette.secondary, in: graphics)
        graphics.setFillColor(context.palette.guide)
        graphics.fill(layout.bar.pixelAligned)
        graphics.fillEllipse(in: layout.shiftLight)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.number(frame.rpm, decimals: 0)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        if let rpm = frame.rpm, rpm.isFinite {
            let fraction = min(max(rpm / max(context.options.maxRPM, 1), 0), 1)
            var fill = layout.bar
            fill.size.width = layout.bar.width * fraction
            graphics.setFillColor(context.palette.accent)
            graphics.fill(fill.pixelAligned)
            if rpm >= context.options.shiftLightRPM {
                graphics.setFillColor(context.palette.warning)
                graphics.fillEllipse(in: layout.shiftLight)
            }
        }
        for text in readouts(frame, context: context) {
            context.draw(text, layout.valueStyle, in: layout.value, alignment: .leading, in: graphics)
        }
    }
}
