import CoreGraphics
import Foundation

/// The temperatures (issue 9.11): water and exhaust, each a label on the left
/// and whole degrees with the unit (`°C` or `°F`) on the right.
struct TemperatureWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// Each row's label slot, top to bottom.
        let labels: [CGRect]
        /// Each row's value slot.
        let values: [CGRect]
        let labelStyle: OverlayTextStyle
        let valueStyle: OverlayTextStyle
    }

    /// The rows' labels, in the export language.
    static func labels(_ context: OverlayWidgetContext) -> [String] {
        [context.label(.overlayLabelWater), context.label(.overlayLabelExhaust)]
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let (top, bottom) = content.divided(atDistance: (content.height / 2).rounded(), from: .maxYEdge)
        let rows = [top, bottom].map { $0.divided(atDistance: ($0.width * 0.4).rounded(), from: .minXEdge) }
        let labels = rows.map(\.slice), values = rows.map(\.remainder)
        let widestLabel = Self.labels(context).reduce("") { $1.count > $0.count ? $1 : $0 }
        return Layout(labels: labels, values: values, labelStyle: context.style(for: labels[0], fitting: widestLabel),
                      valueStyle: context.style(for: values[0], fitting: "8888 " + context.units.temperatureUnit))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        for (label, slot) in zip(Self.labels(context), layout.labels) {
            context.draw(label, layout.labelStyle, in: slot, alignment: .leading, color: context.palette.secondary,
                         in: graphics)
        }
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [frame.waterTemp, frame.exhaustTemp].map { celsius in
            let text = context.formatter.number(celsius.map(context.units.temperature(fromCelsius:)), decimals: 0)
            return text == OverlayFormatter.missing ? text : text + " " + context.units.temperatureUnit
        }
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for (text, slot) in zip(readouts(frame, context: context), layout.values) {
            context.draw(text, layout.valueStyle, in: slot, alignment: .trailing, in: graphics)
        }
    }
}
