import CoreGraphics
import Foundation

/// The kart badge (issue 9.11): the garage kart's specification —
/// "F4 · Thunder · RBC Honda · 18 HP" — drawn once with the static parts; it
/// does not change during a session.
struct KartBadgeWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let text: CGRect
        let style: OverlayTextStyle
    }

    /// What the badge says (``OverlaySessionContext/kartBadgeText``), or nothing
    /// without a kart.
    static func text(_ context: OverlayWidgetContext) -> String {
        context.session.kartBadgeText ?? ""
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        Layout(text: context.content, style: context.style(for: context.content, fitting: Self.text(context)))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(Self.text(context), layout.style, in: layout.text, in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        []
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {}
}
