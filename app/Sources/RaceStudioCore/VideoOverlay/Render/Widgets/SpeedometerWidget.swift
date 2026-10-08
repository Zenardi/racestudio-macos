import CoreGraphics
import Foundation

/// The speed widget as a needle speedometer (issue 9.15): a dial to
/// ``OverlayWidgetOptions/maxSpeed`` (km/h, shown in the layout's units) with
/// round labelled ticks, and the speed in digits inside the dial. Past full
/// scale the needle stops there while the digits read on.
struct SpeedometerWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let dial: DialLayout
    }

    /// The caption under the digits: the layout's speed unit.
    static func caption(_ context: OverlayWidgetContext) -> String {
        context.units.speedUnit
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let formatter = context.formatter
        let fullScale = context.units.speed(fromKilometresPerHour: context.options.maxSpeed)
        let dial = Dial.layout(in: context, scale: DialScale(maximum: fullScale), label: { speed in
            formatter.number(speed, decimals: 0)
        }, caption: Self.caption(context), valueTemplate: "888")
        return Layout(dial: dial)
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        Dial.drawFace(layout.dial, caption: Self.caption(context), redZone: nil, in: graphics, context: context)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.number(frame.speed.map(context.units.speed(fromKilometresPerHour:)), decimals: 0)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        if let speed = frame.speed, speed.isFinite {
            Dial.drawNeedle(at: speed / max(context.options.maxSpeed, 1), on: layout.dial, in: graphics,
                            context: context)
        }
        for text in readouts(frame, context: context) {
            Dial.drawValue(text, on: layout.dial, in: graphics, context: context)
        }
    }
}
