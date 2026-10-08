import CoreGraphics
import Foundation

/// The RPM widget as a needle tachometer (issue 9.15): a dial to
/// ``OverlayWidgetOptions/maxRPM`` labelled in thousands, a red zone from
/// ``OverlayWidgetOptions/shiftLightRPM`` to full scale, the shift light lit at
/// or above it, and the rpm in digits inside the dial. Past full scale the
/// needle stops there while the digits read on.
struct TachometerWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let dial: DialLayout
        /// The shift light, under the top of the scale.
        let shiftLight: CGRect
    }

    /// The caption under the digits — the scale's unit, the same in every language.
    static let caption = "×1000 RPM"

    func layout(in context: OverlayWidgetContext) -> Layout {
        let formatter = context.formatter
        let dial = Dial.layout(in: context, scale: DialScale(maximum: context.options.maxRPM), label: { rpm in
            let thousands = rpm / 1_000
            return formatter.number(thousands, decimals: thousands == thousands.rounded() ? 0 : 1)
        }, caption: Self.caption, valueTemplate: "88888")
        let size = (dial.radius * 0.14).rounded()
        let light = CGRect(x: dial.centre.x - size / 2, y: dial.centre.y + dial.radius * 0.36 - size / 2,
                           width: size, height: size)
        return Layout(dial: dial, shiftLight: light)
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        let options = context.options
        let maximum = max(options.maxRPM, 1)
        let zone = min(max(options.shiftLightRPM / maximum, 0), 1)...1
        Dial.drawFace(layout.dial, caption: Self.caption, redZone: zone, in: graphics, context: context)
        graphics.setFillColor(context.palette.guide)
        graphics.fillEllipse(in: layout.shiftLight)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.number(frame.rpm, decimals: 0)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        if let rpm = frame.rpm, rpm.isFinite {
            if rpm >= context.options.shiftLightRPM {
                graphics.setFillColor(context.palette.warning)
                graphics.fillEllipse(in: layout.shiftLight)
            }
            Dial.drawNeedle(at: rpm / max(context.options.maxRPM, 1), on: layout.dial, in: graphics,
                            context: context)
        }
        for text in readouts(frame, context: context) {
            Dial.drawValue(text, on: layout.dial, in: graphics, context: context)
        }
    }
}
