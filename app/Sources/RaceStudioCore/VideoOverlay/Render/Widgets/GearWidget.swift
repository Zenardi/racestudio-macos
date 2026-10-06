import CoreGraphics
import Foundation

/// The gear readout (issue 9.11): the gear number — `N` in neutral — under a
/// `GEAR` label.
struct GearWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let label: CGRect
        let value: CGRect
        let labelStyle: OverlayTextStyle
        let valueStyle: OverlayTextStyle
    }

    /// The label, in the export language.
    static func label(_ context: OverlayWidgetContext) -> String {
        context.label(.overlayLabelGear)
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let (label, value) = content.divided(atDistance: (content.height * 0.28).rounded(), from: .maxYEdge)
        return Layout(label: label, value: value, labelStyle: context.style(for: label, fitting: Self.label(context)),
                      valueStyle: context.style(for: value, fitting: "8"))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(Self.label(context), layout.labelStyle, in: layout.label, color: context.palette.secondary,
                     in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [context.formatter.gear(frame.gear)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for text in readouts(frame, context: context) {
            context.draw(text, layout.valueStyle, in: layout.value, in: graphics)
        }
    }
}
