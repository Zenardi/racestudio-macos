import CoreGraphics
import Foundation

/// The session info (issue 9.11): venue · date · session name, each left out
/// when unknown — drawn once with the static parts. The logger's `MM/DD/YYYY`
/// date is written `YYYY-MM-DD`, which reads the same in every language.
struct SessionInfoWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let text: CGRect
        let style: OverlayTextStyle
    }

    /// What the widget says, or nothing without session details.
    static func text(_ context: OverlayWidgetContext) -> String {
        guard let metadata = context.session.metadata else { return "" }
        return [metadata.track, date(metadata.logDate), metadata.session]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        Layout(text: context.content, style: context.style(for: context.content, fitting: Self.text(context)))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(Self.text(context), layout.style, in: layout.text, alignment: .leading, in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        []
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {}

    /// The logger's `MM/DD/YYYY` as `YYYY-MM-DD`; anything else as it was logged.
    private static func date(_ logged: String) -> String {
        let parts = logged.trimmingCharacters(in: .whitespaces).split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[0]), (1...31).contains(parts[1]),
              (1000...9999).contains(parts[2]) else { return logged }
        return String(format: "%04d-%02d-%02d", parts[2], parts[0], parts[1])
    }
}
