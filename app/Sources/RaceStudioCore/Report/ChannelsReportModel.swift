import Foundation

/// Whether the report computes one statistic block per lap or subdivides each lap
/// into equal-time segments (issue 8.10).
public enum ReportMode: String, CaseIterable, Sendable, Identifiable {
    /// One column per shown lap.
    case perLap
    /// Each shown lap split into `segmentCount` equal-time segments.
    case perSegment

    public var id: String { rawValue }

    /// The label the mode picker shows.
    public var title: String {
        switch self {
        case .perLap: return "Per Lap"
        case .perSegment: return "Per Segment"
        }
    }
}

/// One report column (issue 8.10): a lap or a segment, carrying the time window its
/// statistics are computed over and the x-position it plots at on the graph (the
/// lap number, plus a fractional offset per segment).
public struct ReportInterval: Equatable, Sendable, Identifiable {
    /// A stable id, unique within a table (`"lap-N"` or `"lap-N-seg-S"`).
    public let id: String
    /// The header label (`"Lap 1"` or `"Lap 1 · S2"`).
    public let label: String
    /// The lap this interval belongs to.
    public let lap: LapID
    /// The graph x-position — the lap number (segments add a within-lap fraction).
    public let x: Double
    /// The inclusive time window `[start, end]` (seconds) the statistics cover.
    public let start: Double
    public let end: Double

    public init(id: String, label: String, lap: LapID, x: Double, start: Double, end: Double) {
        self.id = id
        self.label = label
        self.lap = lap
        self.x = x
        self.start = start
        self.end = end
    }
}

/// One table cell (issue 8.10): a channel's statistics over one column's window,
/// or `nil` when that column has no samples for the channel (a no-data cell).
public struct ReportCell: Equatable, Sendable, Identifiable {
    public let channel: ChannelID
    /// The owning ``ReportInterval/id``.
    public let column: String
    public let statistics: ChannelStatistics?

    public var id: String { "\(channel.name)\u{1F}\(column)" }

    public init(channel: ChannelID, column: String, statistics: ChannelStatistics?) {
        self.channel = channel
        self.column = column
        self.statistics = statistics
    }
}

/// One table row (issue 8.10): a channel and its per-column cells, index-aligned
/// with the table's ``ReportTable/columns``.
public struct ReportRow: Equatable, Sendable, Identifiable {
    public let channel: ChannelID
    public let cells: [ReportCell]

    public var id: String { channel.name }

    public init(channel: ChannelID, cells: [ReportCell]) {
        self.channel = channel
        self.cells = cells
    }
}

/// The assembled report table (issue 8.10): a row per channel, a column per lap (or
/// segment), each cell carrying the full min/max/avg/median statistics. `statistic`
/// is the one the UI currently emphasises and the graph plots.
public struct ReportTable: Equatable, Sendable {
    public let statistic: ReportStatistic
    public let columns: [ReportInterval]
    public let rows: [ReportRow]

    public init(statistic: ReportStatistic, columns: [ReportInterval], rows: [ReportRow]) {
        self.statistic = statistic
        self.columns = columns
        self.rows = rows
    }

    /// Whether the table has nothing to render (no channels or no columns).
    public var isEmpty: Bool { rows.isEmpty || columns.isEmpty }
}

/// One point on the statistic-vs-lap graph (issue 8.10): a column's chosen-statistic
/// value at its lap-number x-position.
public struct ReportPoint: Equatable, Sendable, Identifiable {
    /// The owning ``ReportInterval/id`` — also the hot-track key.
    public let column: String
    public let x: Double
    public let label: String
    public let value: Double

    public var id: String { column }

    public init(column: String, x: Double, label: String, value: Double) {
        self.column = column
        self.x = x
        self.label = label
        self.value = value
    }
}

/// The statistic-vs-lap graph for the selected table row (issue 8.10): the chosen
/// statistic plotted across the columns for one channel, with the hot-tracked point
/// (the selected column) called out. `channel` is `nil` when the table has no rows.
public struct ReportGraph: Equatable, Sendable {
    public let channel: ChannelID?
    public let statistic: ReportStatistic
    public let points: [ReportPoint]
    /// The point for the selected column, when one is selected and has a value.
    public let highlighted: ReportPoint?

    public init(channel: ChannelID?, statistic: ReportStatistic,
                points: [ReportPoint], highlighted: ReportPoint?) {
        self.channel = channel
        self.statistic = statistic
        self.points = points
        self.highlighted = highlighted
    }
}

/// The UI state + assembly for the analysis window's **Channels Report** (issue
/// 8.10): the chosen statistic, the per-lap/segment mode, which table row the graph
/// hot-tracks, and the magic-wand presets — held apart from ``AnalysisWindowModel``
/// (like ``StatsPanelsModel``) so the report's knobs survive layout switches.
///
/// It owns no channel data: ``table(traces:laps:)`` takes the window's already-read
/// ``ChannelTrace``s and the laps to show, slicing each channel per lap/segment and
/// computing ``ChannelStatistics`` — so all of the stat assembly, the graph
/// mapping, and the presets are covered here without the FFI. `@MainActor` because
/// the SwiftUI panel reads it on the main actor (macOS 13 has no `@Observable`).
@MainActor
public final class ChannelsReportModel: ObservableObject {

    /// The segment counts per-segment mode accepts: at least two (one segment is
    /// just the whole lap), up to a readable ceiling.
    public static let segmentCountRange = 2...20

    /// The statistic the table emphasises and the graph plots; average by default.
    @Published public private(set) var statistic: ReportStatistic = .average

    /// Whether columns are laps or per-lap segments; per-lap by default.
    @Published public private(set) var mode: ReportMode = .perLap

    /// How many segments each lap is split into in per-segment mode, clamped to
    /// ``segmentCountRange``.
    @Published public private(set) var segmentCount: Int = 3

    /// The channel whose statistic the graph plots, or `nil` to follow the first
    /// row. Resolved against the current rows at build time, so a stale name simply
    /// falls back rather than needing an explicit cleanup.
    @Published public private(set) var selectedRow: ChannelID?

    /// The column (``ReportInterval/id``) the graph hot-tracks, or `nil` for none.
    @Published public private(set) var highlightedColumn: String?

    /// The preset last applied (drives the menu's checkmark), or `nil`.
    @Published public private(set) var activePreset: ReportPreset?

    public init() {}

    // MARK: - Controls

    /// Choose the statistic the table emphasises and the graph plots.
    public func setStatistic(_ statistic: ReportStatistic) {
        self.statistic = statistic
    }

    /// Switch between per-lap and per-segment columns.
    public func setMode(_ mode: ReportMode) {
        self.mode = mode
    }

    /// Set the per-segment split count, clamped to ``segmentCountRange``.
    public func setSegmentCount(_ count: Int) {
        segmentCount = count.clamped(to: Self.segmentCountRange)
    }

    /// Select the table row (channel) the graph plots (`nil` follows the first row).
    public func selectRow(_ channel: ChannelID?) {
        selectedRow = channel
    }

    /// Hot-track the given column on the graph (a `nil`/empty id clears it).
    public func highlightColumn(_ column: String?) {
        highlightedColumn = column.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Apply a magic-wand preset: adopt its default statistic and record it as
    /// active. The relevant channel set is chosen via
    /// ``ReportPreset/matchingChannels(in:)`` and applied by the caller to the
    /// window's selection, so the report and the other panels stay in sync.
    public func applyPreset(_ preset: ReportPreset) {
        statistic = preset.defaultStatistic
        activePreset = preset
    }

    // MARK: - Table assembly

    /// The report columns for `laps` under the current mode: one per lap, or — in
    /// per-segment mode — `segmentCount` equal-time segments per lap. De-duplicated
    /// by id (a duplicate lap index collapses to the first).
    public func intervals(for laps: [Lap]) -> [ReportInterval] {
        let raw: [ReportInterval]
        switch mode {
        case .perLap:
            raw = laps.map { lap in
                let number = Int(lap.index) + 1
                return ReportInterval(id: "lap-\(lap.index)", label: "Lap \(number)",
                                      lap: LapID(Int(lap.index)), x: Double(number),
                                      start: lap.startTimeS, end: lap.endTimeS)
            }
        case .perSegment:
            raw = laps.flatMap { segments(of: $0) }
        }
        var seen = Set<String>()
        return raw.filter { seen.insert($0.id).inserted }
    }

    /// The assembled report: a row per channel, a column per lap/segment, each cell
    /// the channel's ``ChannelStatistics`` over that column's window (`nil` when the
    /// window holds no samples). Duplicate channel names collapse to the first trace,
    /// so the grid never has two rows with the same identity.
    public func table(traces: [ChannelTrace], laps: [Lap]) -> ReportTable {
        let columns = intervals(for: laps)
        var seenChannels = Set<String>()
        let rows = traces.compactMap { trace -> ReportRow? in
            guard seenChannels.insert(trace.name).inserted else { return nil }
            let channel = ChannelID(trace.name)
            let series = ChannelSeries(xs: trace.samples.map(\.time), values: trace.samples.map(\.value))
            let cells = columns.map { column -> ReportCell in
                let slice = series.windowed(from: column.start, through: column.end)
                return ReportCell(channel: channel, column: column.id,
                                  statistics: ChannelStatistics.from(slice.values))
            }
            return ReportRow(channel: channel, cells: cells)
        }
        return ReportTable(statistic: statistic, columns: columns, rows: rows)
    }

    // MARK: - Graph (hot-track row → statistic-vs-lap points)

    /// The statistic-vs-lap graph for the selected row (issue 8.10): the chosen
    /// statistic across the table's columns for the resolved channel, with the
    /// selected column called out as the hot-tracked point. Empty when the table has
    /// no rows.
    public func graph(from table: ReportTable) -> ReportGraph {
        guard let channel = resolvedSelectedRow(table.rows.map(\.channel)),
              let row = table.rows.first(where: { $0.channel == channel }) else {
            return ReportGraph(channel: nil, statistic: table.statistic, points: [], highlighted: nil)
        }
        let points = zip(table.columns, row.cells).compactMap { column, cell -> ReportPoint? in
            guard let value = cell.statistics?.value(for: table.statistic), value.isFinite else { return nil }
            return ReportPoint(column: column.id, x: column.x, label: column.label, value: value)
        }
        let highlighted = highlightedColumn.flatMap { id in points.first { $0.column == id } }
        return ReportGraph(channel: channel, statistic: table.statistic,
                           points: points, highlighted: highlighted)
    }

    /// The channel the graph plots: the selected row while it is still a table row,
    /// else the first row. `nil` when the table has no rows.
    public func resolvedSelectedRow(_ channels: [ChannelID]) -> ChannelID? {
        if let selectedRow, channels.contains(selectedRow) { return selectedRow }
        return channels.first
    }

    // MARK: - Internals

    /// One lap split into ``segmentCount`` equal-time segments. A zero-width lap (or
    /// a degenerate count) yields a single whole-lap segment rather than nothing.
    private func segments(of lap: Lap) -> [ReportInterval] {
        let number = Int(lap.index) + 1
        let id = LapID(Int(lap.index))
        let span = lap.endTimeS - lap.startTimeS
        guard span > 0, segmentCount > 0 else {
            return [ReportInterval(id: "lap-\(lap.index)-seg-0", label: "Lap \(number) · S1",
                                   lap: id, x: Double(number), start: lap.startTimeS, end: lap.endTimeS)]
        }
        let width = span / Double(segmentCount)
        return (0..<segmentCount).map { segment in
            let start = lap.startTimeS + Double(segment) * width
            // The last segment ends exactly at the lap end (no floating-point gap).
            let end = segment == segmentCount - 1 ? lap.endTimeS : start + width
            return ReportInterval(id: "lap-\(lap.index)-seg-\(segment)",
                                  label: "Lap \(number) · S\(segment + 1)", lap: id,
                                  x: Double(number) + Double(segment) / Double(segmentCount),
                                  start: start, end: end)
        }
    }
}
