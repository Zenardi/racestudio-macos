import CoreGraphics
import Foundation

/// The current lap's sector splits, F1-style (issues 9.11, 9.17): one row per
/// sector of the lap the frame is on, top to bottom in track order —
///
/// - a **done** sector's time and its signed gap to the best so far, in purple
///   when it is at or under that best and in yellow when it is over it
///   (neutral, with no gap, when there is nothing to compare with — colour is
///   never the only signal);
/// - the **running** sector's time so far, highlighted;
/// - `—` for the sectors still to come.
///
/// Each row starts with a bar in its colour. Outside a lap, or on a lap the
/// split timeline does not divide, a single `—`.
///
/// Rows keep one size, an eighth of the widget's height, whatever the count,
/// so the widget's rect holds ``maximumRows`` of them; the plate covers only
/// the top rows the session's sectors need.
struct SectorTimesWidget: OverlayWidgetDrawer {

    /// The most rows drawn; a lap cut finer shows its first sectors.
    static let maximumRows = 8

    /// The plate's padding round the rows, in rows.
    private static let paddingRows: CGFloat = 0.4

    struct Layout: Sendable {
        /// The plate: the top of the widget's rect, as tall as its rows.
        let plate: CGRect
        /// The rows, top to bottom: one per sector of the session's most
        /// divided lap (at most ``maximumRows``), and at least one.
        let rows: [Row]
        /// The text styles every row uses.
        let styles: Styles
    }

    /// One row's parts.
    struct Row: Sendable {
        let frame: CGRect
        /// The sector's colour bar, at the leading edge.
        let bar: CGRect
        let name: CGRect
        let time: CGRect
        let gap: CGRect
    }

    struct Styles: Sendable {
        let name: OverlayTextStyle
        let time: OverlayTextStyle
        let gap: OverlayTextStyle
    }

    /// What one row shows at the frame's instant.
    private struct Entry {
        let name: String
        let time: String
        let gap: String?
        let color: CGColor
        let bar: CGColor
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let rect = context.rect
        let height = (rect.height / (CGFloat(Self.maximumRows) + 2 * Self.paddingRows)).rounded(.down)
        let padding = (height * Self.paddingRows).rounded(.down)
        let count = min(max(context.sectors.laps.map(\.sectors.count).max() ?? 0, 1), Self.maximumRows)
        let plateHeight = CGFloat(count) * height + 2 * padding
        let plate = CGRect(x: rect.minX, y: rect.maxY - plateHeight, width: rect.width, height: plateHeight)
        let rows = (0..<count).map { index in
            Self.row(CGRect(x: rect.minX + padding, y: rect.maxY - padding - CGFloat(index + 1) * height,
                            width: max(rect.width - 2 * padding, 0), height: height))
        }
        let first = rows[0]
        let styles = Styles(name: context.style(for: first.name, fitting: "S88"),
                            time: context.style(for: first.time, fitting: "8:88.888"),
                            gap: context.style(for: first.gap, fitting: "+888.888"))
        return Layout(plate: plate, rows: rows, styles: styles)
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics, over: layout.plate)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        let rows = entries(frame, context: context)
        guard !rows.isEmpty else { return [OverlayFormatter.missing] }
        return rows.flatMap { [$0.name, $0.time] + ($0.gap.map { [$0] } ?? []) }
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        let rows = entries(frame, context: context)
        guard !rows.isEmpty else {
            context.draw(OverlayFormatter.missing, layout.styles.time, in: layout.rows[0].frame, in: graphics)
            return
        }
        for (entry, row) in zip(rows, layout.rows) {
            let bar = row.bar.pixelAligned
            graphics.addPath(CGPath(roundedRect: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2,
                                    transform: nil))
            graphics.setFillColor(entry.bar)
            graphics.fillPath()
            context.draw(entry.name, layout.styles.name, in: row.name, alignment: .leading,
                         color: context.palette.secondary, in: graphics)
            context.draw(entry.time, layout.styles.time, in: row.time, alignment: .trailing, color: entry.color,
                         in: graphics)
            if let gap = entry.gap {
                context.draw(gap, layout.styles.gap, in: row.gap, alignment: .trailing, color: entry.color,
                             in: graphics)
            }
        }
    }

    // MARK: - Internals

    /// `frame`'s parts: the bar, then the name, the time and the gap, the
    /// last two apart by a gutter.
    private static func row(_ frame: CGRect) -> Row {
        let barWidth = max((frame.height * 0.16).rounded(), 2)
        let space = (frame.height * 0.3).rounded()
        let bar = CGRect(x: frame.minX, y: frame.minY + frame.height * 0.15, width: barWidth,
                         height: frame.height * 0.7)
        let text = max(frame.width - barWidth - 2 * space, 0)
        let name = CGRect(x: bar.maxX + space, y: frame.minY, width: (text * 0.18).rounded(), height: frame.height)
        let time = CGRect(x: name.maxX, y: frame.minY, width: ((text - name.width) / 2).rounded(.down),
                          height: frame.height)
        let gap = CGRect(x: time.maxX + space, y: frame.minY, width: max(frame.maxX - time.maxX - space, 0),
                         height: frame.height)
        return Row(frame: frame, bar: bar, name: name, time: time, gap: gap)
    }

    /// Each sector of the frame's lap, with what its row says.
    private func entries(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [Entry] {
        guard let reading = frame.lap, let lap = context.sectors.lapSpan(reading.lap), !lap.sectors.isEmpty
        else { return [] }
        let formatter = context.formatter, palette = context.palette
        return SectorSplit.splits(of: lap, at: frame.time, reading: reading).prefix(Self.maximumRows).map { split in
            switch split.progress {
            case let .done(time, gap, pace):
                let color = Self.color(of: pace, in: palette)
                return Entry(name: split.name, time: formatter.sectorTime(time),
                             gap: gap.map { formatter.signed($0, decimals: 3) }, color: color,
                             bar: pace == .unrated ? palette.secondary : color)
            case let .running(elapsed):
                // A clock just started reads zero, not "no time".
                let time = elapsed > 0 ? formatter.sectorTime(elapsed) : formatter.number(0, decimals: 3)
                return Entry(name: split.name, time: time, gap: nil, color: palette.accent, bar: palette.accent)
            case .upcoming:
                return Entry(name: split.name, time: OverlayFormatter.missing, gap: nil, color: palette.text,
                             bar: palette.guide)
            }
        }
    }

    /// A done sector's colour: purple, yellow, or the readout colour.
    private static func color(of pace: SectorPace, in palette: OverlayPalette) -> CGColor {
        switch pace {
        case .best: return palette.sectorBest
        case .slower: return palette.sectorSlower
        case .unrated: return palette.text
        }
    }
}
