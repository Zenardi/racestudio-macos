import CoreGraphics
import Foundation

/// The speed readout (issue 9.11): big whole-number digits with the unit
/// (`km/h` or `mph`) under them.
struct SpeedWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// Where the digits go.
        let value: CGRect
        /// Where the unit goes.
        let unit: CGRect
        let valueStyle: OverlayTextStyle
        let unitStyle: OverlayTextStyle
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let (unit, value) = content.divided(atDistance: (content.height * 0.3).rounded(), from: .minYEdge)
        return Layout(value: value, unit: unit, valueStyle: context.style(for: value, fitting: "888"),
                      unitStyle: context.style(for: unit, fitting: context.units.speedUnit))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(context.units.speedUnit, layout.unitStyle, in: layout.unit, color: context.palette.secondary,
                     in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.number(frame.speed.map(context.units.speed(fromKilometresPerHour:)), decimals: 0)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for text in readouts(frame, context: context) {
            context.draw(text, layout.valueStyle, in: layout.value, in: graphics)
        }
    }
}
