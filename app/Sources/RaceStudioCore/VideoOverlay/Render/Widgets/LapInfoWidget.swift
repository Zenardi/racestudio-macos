import CoreGraphics
import Foundation

/// Lap info (issue 9.11): three rows — the lap number, the last completed lap's
/// time and the best lap so far — each a label on the left and its value on the
/// right. At the start of a lap the last row already shows the lap just
/// finished.
struct LapInfoWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// The rows, top to bottom.
        let rows: [CGRect]
        /// Each row's label slot.
        let labels: [CGRect]
        /// Each row's value slot.
        let values: [CGRect]
        let labelStyle: OverlayTextStyle
        let valueStyle: OverlayTextStyle
    }

    /// The rows' labels, in the export language.
    static func labels(_ context: OverlayWidgetContext) -> [String] {
        [context.label(.overlayLabelLap), context.label(.overlayLabelLast), context.label(.overlayLabelBest)]
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let height = (content.height / 3).rounded(.down)
        let rows = (0..<3).map { index in
            CGRect(x: content.minX, y: content.maxY - CGFloat(index + 1) * height, width: content.width,
                   height: height)
        }
        let split = rows.map { $0.divided(atDistance: ($0.width * 0.4).rounded(), from: .minXEdge) }
        let labels = split.map(\.slice), values = split.map(\.remainder)
        let widestLabel = Self.labels(context).reduce("") { $1.count > $0.count ? $1 : $0 }
        return Layout(rows: rows, labels: labels, values: values,
                      labelStyle: context.style(for: labels[0], fitting: widestLabel),
                      valueStyle: context.style(for: values[0], fitting: "8:88.888"))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        for (label, slot) in zip(Self.labels(context), layout.labels) {
            context.draw(label, layout.labelStyle, in: slot, alignment: .leading, color: context.palette.secondary,
                         in: graphics)
        }
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        guard let lap = frame.lap else { return Array(repeating: OverlayFormatter.missing, count: 3) }
        return [String(lap.number), context.formatter.lapTime(lap.last?.time),
                context.formatter.lapTime(lap.bestSoFar?.time)]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for (text, slot) in zip(readouts(frame, context: context), layout.values) {
            context.draw(text, layout.valueStyle, in: slot, alignment: .trailing, in: graphics)
        }
    }
}
