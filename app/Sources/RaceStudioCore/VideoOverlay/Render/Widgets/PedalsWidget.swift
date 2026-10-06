import CoreGraphics
import Foundation

/// The pedals (issue 9.11): throttle and brake as two bars filled from the
/// bottom, in the gain and loss colours, labelled under them. Each bar is full
/// at its pedal's full scale (``OverlayWidgetOptions/throttleFullScale``,
/// ``OverlayWidgetOptions/brakeFullScale``) — `100` by default, a percentage of
/// travel; set it to, say, the brake pressure at full braking for a brake
/// logged in bar — and clamped there. A pedal with no value shows `—` in its bar.
struct PedalsWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        /// The throttle bar at full travel.
        let throttle: CGRect
        /// The brake bar at full travel.
        let brake: CGRect
        /// The labels under the bars.
        let labels: [CGRect]
        let labelStyle: OverlayTextStyle
        let missingStyle: OverlayTextStyle
    }

    /// The bars' labels, in the export language.
    static func labels(_ context: OverlayWidgetContext) -> [String] {
        [context.label(.overlayLabelThrottle), context.label(.overlayLabelBrake)]
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let gap = max(1, (content.width * 0.12).rounded())
        let (labelRow, rest) = content.divided(atDistance: (content.height * 0.22).rounded(), from: .minYEdge)
        let bars = rest.divided(atDistance: gap / 2, from: .minYEdge).remainder
        let width = ((bars.width - gap) / 2).rounded(.down)
        let throttle = CGRect(x: bars.minX, y: bars.minY, width: width, height: bars.height)
        let brake = CGRect(x: bars.maxX - width, y: bars.minY, width: width, height: bars.height)
        let labels = [CGRect(x: throttle.minX, y: labelRow.minY, width: width, height: labelRow.height),
                      CGRect(x: brake.minX, y: labelRow.minY, width: width, height: labelRow.height)]
        let missing = CGRect(x: throttle.minX, y: throttle.midY - labelRow.height / 2, width: width,
                             height: labelRow.height)
        return Layout(throttle: throttle, brake: brake, labels: labels,
                      labelStyle: context.style(for: labels[0], fitting: "M"),
                      missingStyle: context.style(for: missing, fitting: OverlayFormatter.missing))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        graphics.setFillColor(context.palette.guide)
        graphics.fill(layout.throttle.pixelAligned)
        graphics.fill(layout.brake.pixelAligned)
        for (label, slot) in zip(Self.labels(context), layout.labels) {
            context.draw(label, layout.labelStyle, in: slot, color: context.palette.secondary, in: graphics)
        }
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        [frame.throttle, frame.brake].compactMap { Self.fraction($0, of: 1) == nil ? OverlayFormatter.missing : nil }
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        let options = context.options
        let pedals = [(Self.fraction(frame.throttle, of: options.throttleFullScale), layout.throttle,
                       context.palette.gain),
                      (Self.fraction(frame.brake, of: options.brakeFullScale), layout.brake, context.palette.loss)]
        for (fraction, bar, color) in pedals {
            guard let fraction else {
                let slot = CGRect(x: bar.minX, y: bar.midY - bar.width / 2, width: bar.width, height: bar.width)
                context.draw(OverlayFormatter.missing, layout.missingStyle, in: slot, in: graphics)
                continue
            }
            graphics.setFillColor(color)
            graphics.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: bar.height * fraction)
                .pixelAligned)
        }
    }

    /// A pedal value as a share of `fullScale`, clamped to `0…1`; `nil` when missing.
    private static func fraction(_ value: Double?, of fullScale: Double) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return CGFloat(min(max(value / max(fullScale, OverlayWidgetOptions.pedalFullScaleLimits.lowerBound), 0), 1))
    }
}
