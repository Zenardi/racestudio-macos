import CoreGraphics
import Foundation

/// The current lap's sector times (issue 9.11): one row per sector of the lap
/// the frame is on — a finished sector's time, the running sector's time so far
/// (highlighted), `—` for the sectors still to come. Outside a lap, or on a lap
/// the split timeline does not divide, a single `—`.
struct SectorTimesWidget: OverlayWidgetDrawer {

    /// The most rows drawn; a lap cut finer shows its first sectors.
    static let maximumRows = 8

    struct Layout: Sendable {
        let content: CGRect
        /// The text styles for `n` rows (`n` in `1…maximumRows`), at `n − 1`.
        let styles: [(name: OverlayTextStyle, time: OverlayTextStyle)]

        /// The rows for `count` sectors, top to bottom — never fewer than three
        /// rows' height, so a two-sector lap is not drawn huge.
        func rows(for count: Int) -> [CGRect] {
            let height = (content.height / CGFloat(max(count, 3))).rounded(.down)
            return (0..<count).map { index in
                CGRect(x: content.minX, y: content.maxY - CGFloat(index + 1) * height, width: content.width,
                       height: height)
            }
        }

        /// A row's name and time slots.
        static func slots(of row: CGRect) -> (name: CGRect, time: CGRect) {
            let split = row.divided(atDistance: (row.width * 0.35).rounded(), from: .minXEdge)
            return (split.slice, split.remainder)
        }
    }

    /// One sector's row at the frame's instant.
    private struct Entry {
        let name: String
        let time: String
        /// Whether it is the sector being driven.
        let isRunning: Bool
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let blank = Layout(content: context.content, styles: [])
        let styles = (1...Self.maximumRows).map { count -> (name: OverlayTextStyle, time: OverlayTextStyle) in
            let slots = Layout.slots(of: blank.rows(for: count)[0])
            return (context.style(for: slots.name, fitting: "S88"), context.style(for: slots.time, fitting: "8:88.888"))
        }
        return Layout(content: context.content, styles: styles)
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        let rows = entries(frame, context: context)
        return rows.isEmpty ? [OverlayFormatter.missing] : rows.flatMap { [$0.name, $0.time] }
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        let rows = entries(frame, context: context)
        guard !rows.isEmpty else {
            let slot = layout.rows(for: 1)[0]
            context.draw(OverlayFormatter.missing, layout.styles[0].time, in: slot, in: graphics)
            return
        }
        let styles = layout.styles[rows.count - 1]
        for (entry, row) in zip(rows, layout.rows(for: rows.count)) {
            let slots = Layout.slots(of: row)
            context.draw(entry.name, styles.name, in: slots.name, alignment: .leading,
                         color: context.palette.secondary, in: graphics)
            let color = entry.isRunning ? context.palette.accent : context.palette.text
            context.draw(entry.time, styles.time, in: slots.time, alignment: .trailing, color: color, in: graphics)
        }
    }

    // MARK: - Internals

    /// Each sector of the frame's lap, with what its row says.
    private func entries(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [Entry] {
        guard let lap = frame.lap, let sectors = context.sectors.lapSpan(lap.lap)?.sectors, !sectors.isEmpty
        else { return [] }
        let formatter = context.formatter
        return sectors.prefix(Self.maximumRows).map { sector in
            if frame.time >= sector.span.end {
                return Entry(name: sector.name, time: formatter.sectorTime(sector.duration), isRunning: false)
            }
            if sector.span.contains(frame.time) {
                // A clock just started reads zero, not "no time".
                let running = frame.time - sector.span.start
                let text = running > 0 ? formatter.sectorTime(running) : formatter.number(0, decimals: 3)
                return Entry(name: sector.name, time: text, isRunning: true)
            }
            return Entry(name: sector.name, time: OverlayFormatter.missing, isRunning: false)
        }
    }
}
