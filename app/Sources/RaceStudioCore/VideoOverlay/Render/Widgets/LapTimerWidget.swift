import CoreGraphics
import Foundation

/// The lap timer (issue 9.11): the running time since the lap's beacon,
/// `m:ss.mmm` in monospaced digits, so it ticks without jittering.
struct LapTimerWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let value: CGRect
        let valueStyle: OverlayTextStyle
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        Layout(value: context.content, valueStyle: context.style(for: context.content, fitting: "8:88.888"))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.lapTime(frame.lap?.elapsed)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for text in readouts(frame, context: context) {
            context.draw(text, layout.valueStyle, in: layout.value, in: graphics)
        }
    }
}
