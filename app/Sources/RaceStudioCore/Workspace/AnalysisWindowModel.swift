import Foundation
import Combine

/// The `@MainActor` Core state behind the analysis window shell (issue 8.3): the
/// rail's panel set + active layout, the channel/lap selection, and the window's
/// shared ``LinkedCursor`` — everything the thin `AnalysisWindowView` binds to.
///
/// It reads traces and measures for the selected channels through the 8.1
/// ``AnalysisSession`` (behind the ``SessionDataSource`` seam, so it is covered
/// FFI-free). Selecting a layout only swaps ``activeLayout``; the selection and
/// the cursor live here, so they survive the swap. Reads happen once per
/// selection change and are cached, so scrubbing the cursor re-interpolates the
/// cached samples rather than re-reading the channel each move.
///
/// `@MainActor` because it owns the (main-actor) ``AnalysisSession`` and cursor
/// and is observed by the UI on the main actor; macOS 13 has no `@Observable`,
/// so it is an `ObservableObject`.
@MainActor
public final class AnalysisWindowModel: ObservableObject {

    /// The decoded session presented by the window.
    public let session: Session

    /// The layouts the rail offers, in display order.
    public let layouts: [WindowLayout]

    /// The active layout the central host renders.
    @Published public private(set) var activeLayout: WindowLayout

    /// The channel + lap selection, preserved across layout switches.
    @Published public private(set) var selection: AnalysisSelection

    /// The channel search text for the side panel (issue 8.4); empty lists every
    /// channel.
    @Published public private(set) var channelQuery: String = ""

    /// The channel ordering for the side panel (issue 8.4).
    @Published public private(set) var channelSort: ChannelSort = .configuration

    /// The channels pinned as large digital readouts in the measures panel, in the
    /// order they were pinned (issue 8.5).
    @Published public private(set) var pinnedChannels: [ChannelID] = []

    /// How many sectors the track map splits the lap into (issue 8.6); `3` by
    /// default (the common motorsport count). `0` hides the split markers.
    @Published public private(set) var sectorSplits: Int = 3

    /// The window-level shared cursor every panel links against.
    public let linkedCursor: LinkedCursor

    /// The live analysis pump, or `nil` when the loader vends no data source
    /// (the non-FFI test loaders) — then traces and measures are empty.
    private let analysis: AnalysisSession?

    /// Channel name → channel index, so a `ChannelID` selection maps back onto the
    /// index-addressed ``AnalysisSession`` reads (first occurrence wins).
    private let channelIndexByID: [ChannelID: Int]

    /// Lap id → lap, so a selected `LapID` maps back onto its time window when the
    /// readout grid slices each channel per lap (first occurrence wins).
    private let lapByID: [LapID: Lap]

    /// Cached read of the selected channels — rebuilt only when the selection
    /// changes — so a cursor move re-interpolates without re-reading the channels.
    private var selectionData: [SelectionEntry] = []

    /// The channels × selected-laps readout grid, rebuilt only when the channel or
    /// lap selection changes (issue 8.5). The cursor is applied at read time by
    /// ``ReadoutTableModel/cells(atX:)``, so scrubbing re-interpolates this cache
    /// rather than re-slicing the channels.
    private var readoutTableCache = ReadoutTableModel(rows: [], columns: [], series: [:])

    /// Per-selected-channel formatters, cached alongside the grid so a cursor-move
    /// render reads them without rebuilding the dictionary each time (issue 8.5).
    private var channelFormattersCache: [ChannelID: ChannelFormatter] = [:]

    /// The session's GPS racing line, read once from the pump (it is constant for
    /// the session; only its colour-by-channel changes) — issue 8.6.
    private let gpsTrackPoints: [GPSTrackPoint]

    /// The assembled track-map inputs, rebuilt when the selection or colour channel
    /// changes (issue 8.6). The line is constant; the rebuild only re-aligns the
    /// colour channel onto the fixes.
    private var trackMapCache = TrackMapModel(track: [])

    /// The distance-aligned overlay laps and the delta-t strips keyed by
    /// `(reference, other lap)`, rebuilt on a lap/channel selection change (8.7).
    private var overlayLapsCache: [OverlayLap] = []
    private var overlayDeltasCache: [DeltaPair: [DeltaSample]] = [:]

    /// The channel explicitly chosen to colour the line, or `nil` to follow the
    /// first selected channel (issue 8.6). `@Published` so a colour-picker change
    /// (via ``setColorChannel(_:)``) notifies observers even though the resulting
    /// ``trackMap`` is a plain cache.
    @Published private var colorChannelOverride: ChannelID?

    private struct SelectionEntry {
        let channel: ChannelID
        let trace: ChannelTrace
        let series: ChannelSeries
        let formatter: ChannelFormatter
    }

    /// - Parameters:
    ///   - session: the decoded session (metadata/channels/laps).
    ///   - analysis: the live pump for windowed sample reads, or `nil`.
    ///   - layouts: the rail's panel set (defaults to every ``WindowLayout``).
    public init(session: Session, analysis: AnalysisSession?,
                layouts: [WindowLayout] = WindowLayout.allCases) {
        self.session = session
        self.analysis = analysis
        self.layouts = layouts
        self.activeLayout = layouts.first ?? .timeDistance

        var index: [ChannelID: Int] = [:]
        for (offset, channel) in session.channels.enumerated() {
            let id = ChannelID(channel.name)
            if index[id] == nil { index[id] = offset }
        }
        self.channelIndexByID = index

        var lapIndex: [LapID: Lap] = [:]
        for lap in session.laps {
            let id = LapID(Int(lap.index))
            if lapIndex[id] == nil { lapIndex[id] = lap }
        }
        self.lapByID = lapIndex

        // Default-select the first channel so the window opens on a live plot.
        var selection = AnalysisSelection()
        if let first = session.channels.first {
            selection.toggleChannel(ChannelID(first.name))
        }
        self.selection = selection

        // The cursor's basis is the session's time extent — the lap span, or the
        // selected channel's sample extent when the session has no laps. The
        // distance basis is a placeholder until real distances are wired in a
        // later issue, so the window scrubs on the time axis.
        let basis = analysisCursorTimeBasis(session: session, analysis: analysis,
                                            channelIndexByID: index, selection: selection)
        self.linkedCursor = LinkedCursor(times: basis.times, distances: basis.distances,
                                         time: basis.times.first ?? 0)

        // The GPS racing line is constant for the session, so read it once here;
        // `rebuildSelectionData` then only re-aligns the colour channel onto it.
        self.gpsTrackPoints = analysis?.gpsTrack() ?? []

        rebuildSelectionData()
    }

    /// Convenience over the loaded ``SessionViewModel`` (issue 8.1), so the shell
    /// builds the window straight from the store's `.loaded` state.
    public convenience init(viewModel: SessionViewModel,
                            layouts: [WindowLayout] = WindowLayout.allCases) {
        self.init(session: viewModel.session, analysis: viewModel.analysis, layouts: layouts)
    }

    // MARK: - Layout rail

    /// Make `layout` the active panel (a no-op for a layout not in ``layouts``).
    /// The selection and cursor are untouched, so switching layouts preserves
    /// them.
    public func select(layout: WindowLayout) {
        guard layouts.contains(layout) else { return }
        activeLayout = layout
    }

    // MARK: - Side panel

    /// Toggle `channel` in the selection and refresh the cached traces/measures.
    public func toggleChannel(_ channel: ChannelID) {
        selection.toggleChannel(channel)
        // A deselected channel is no longer a grid row nor a colourable channel, so
        // drop any stale pin / colour override — otherwise it would silently linger
        // and resurrect on re-selection.
        if !selection.channels.contains(channel) {
            pinnedChannels.removeAll { $0 == channel }
            if colorChannelOverride == channel { colorChannelOverride = nil }
        }
        rebuildSelectionData()
    }

    /// Toggle `lap` in the selection and refresh the readout grid's columns and the
    /// lap overlay (which laps are overlaid, issue 8.7).
    public func toggleLap(_ lap: LapID) {
        selection.toggleLap(lap)
        rebuildReadoutTable()
        rebuildOverlay()
    }

    /// Make `lap` the reference the measures panel and delta strip compare against
    /// (issues 8.5 / 8.7), selecting it if needed, and refresh the grid (a
    /// newly-added reference adds a column) and the overlay deltas.
    public func setReferenceLap(_ lap: LapID) {
        selection.setReferenceLap(lap)
        rebuildReadoutTable()
        rebuildOverlay()
    }

    /// Pin or unpin `channel` as a large digital readout in the measures panel
    /// (issue 8.5). Pinning does not change the grid, only which channels also
    /// render as big numbers.
    public func togglePinned(_ channel: ChannelID) {
        if let index = pinnedChannels.firstIndex(of: channel) {
            pinnedChannels.remove(at: index)
        } else {
            pinnedChannels.append(channel)
        }
    }

    /// Set the side panel's channel search text (issue 8.4).
    public func setChannelQuery(_ query: String) {
        channelQuery = query
    }

    /// Set the side panel's channel ordering (issue 8.4).
    public func setChannelSort(_ sort: ChannelSort) {
        channelSort = sort
    }

    /// The channels & laps side panel derived from the current session, selection,
    /// query, and sort (issue 8.4). Rebuilt on demand — a cheap pass over the
    /// channel/lap listings — so it always reflects the latest selection.
    public var sidePanel: ChannelLapSelectionModel {
        ChannelLapSelectionModel(channels: session.channels, laps: session.laps,
                                 selection: selection, query: channelQuery, sort: channelSort)
    }

    // MARK: - Central host (Time/Distance)

    /// The traces for the selected channels, in selection order — the input to
    /// the reused `TimeDistancePlotView`. Empty when there is no analysis pump.
    public var traces: [ChannelTrace] {
        selectionData.map(\.trace)
    }

    // MARK: - Measures bar

    /// The value-at-cursor for each selected channel, in selection order. Reads
    /// the shared cursor's time position and interpolates the cached samples, so
    /// it updates on every cursor move without re-reading the channels.
    public var measures: [ChannelMeasure] {
        let x = linkedCursor.timePosition
        return selectionData.map { entry in
            let readout = ValueAtCursor.value(at: x, in: entry.series)
            return ChannelMeasure(channel: entry.channel, readout: readout,
                                  formatted: entry.formatter.string(for: readout.value))
        }
    }

    // MARK: - Channel table / measures panel (issue 8.5)

    /// The channels × selected-laps value-at-cursor grid feeding the reused
    /// `ChannelTableView`. Read it at the shared cursor with
    /// ``ReadoutTableModel/cells(atX:)`` / ``ReadoutTableModel/deltaCells(atX:reference:)``;
    /// the reference lap is ``selection``'s ``AnalysisSelection/laps`` reference.
    public var readoutTable: ReadoutTableModel { readoutTableCache }

    /// The unit + precision formatter for each selected channel (issue 8.5), so
    /// the panel renders each cell in the channel's own units. Cached, so a
    /// cursor-move render does not rebuild the dictionary.
    public var channelFormatters: [ChannelID: ChannelFormatter] { channelFormattersCache }

    // MARK: - Track map (issue 8.6)

    /// The assembled racing line, colour-by-channel values, colour scale, and
    /// cursor↔fix mapping feeding the reused `TrackMapView`. Empty when the session
    /// has no GPS track (or no analysis pump).
    public var trackMap: TrackMapModel { trackMapCache }

    /// The channel currently colouring the racing line (issue 8.6): the explicit
    /// override while it stays selected, else the first selected channel. `nil`
    /// when nothing is selected.
    public var colorChannel: ChannelID? {
        if let override = colorChannelOverride, selection.channels.contains(override) { return override }
        return selection.channels.first
    }

    /// The GPS fix index under the shared cursor — the marker position on the map
    /// (issue 8.6). Reads the live cursor, so it follows every cursor move; `nil`
    /// when the session has no GPS track.
    public var gpsCursorIndex: Int? {
        trackMapCache.index(atTime: linkedCursor.timePosition)
    }

    /// Colour the racing line by `channel` (issue 8.6); ignored when it is not a
    /// selected channel (only a plotted channel can colour the line).
    public func setColorChannel(_ channel: ChannelID) {
        guard selection.channels.contains(channel) else { return }
        colorChannelOverride = channel
        rebuildTrackMap()
    }

    /// Set how many sectors the track map splits the lap into (issue 8.6); clamped
    /// to be non-negative (`0` hides the markers).
    public func setSectorSplits(_ splits: Int) {
        sectorSplits = max(0, splits)
    }

    /// Move the shared cursor to GPS fix `index` — a hover / click on the map
    /// drives the window's cursor (issue 8.6). A no-op for an out-of-range index or
    /// a dropped fix with no finite time.
    public func moveTrackCursor(toFix index: Int) {
        guard let time = trackMapCache.time(atIndex: index), time.isFinite else { return }
        linkedCursor.moveTime(time)
    }

    // MARK: - Lap overlay (issue 8.7)

    /// The distance-aligned overlay laps for the selected laps, carrying the
    /// ``overlayChannel`` — the input to the reused `LapOverlayViewModel`.
    public var overlayLaps: [OverlayLap] { overlayLapsCache }

    /// The reference lap's delta-t versus each other selected lap, keyed by
    /// ``DeltaPair`` for ``LapOverlayViewModel`` (issue 8.7).
    public var overlayDeltas: [DeltaPair: [DeltaSample]] { overlayDeltasCache }

    /// The channel overlaid across the laps — the first selected channel, `""` when none.
    public var overlayChannel: String { selection.channels.first?.name ?? "" }

    // MARK: - Internals

    /// Re-read the selected channels once (trace + series + formatter), so cursor
    /// moves re-interpolate the cache rather than re-reading across the seam. Also
    /// refreshes the readout grid, whose per-lap slices derive from these series.
    private func rebuildSelectionData() {
        defer {
            rebuildReadoutTable()
            rebuildTrackMap()
            rebuildOverlay()
            var formatters: [ChannelID: ChannelFormatter] = [:]
            for entry in selectionData { formatters[entry.channel] = entry.formatter }
            channelFormattersCache = formatters
        }
        guard let analysis else { selectionData = []; return }
        selectionData = selection.channels.compactMap { id in
            guard let index = channelIndexByID[id] else { return nil }
            let trace = analysis.trace(channelIndex: index)
            let series = ChannelSeries(xs: trace.samples.map(\.time), values: trace.samples.map(\.value))
            let channel = session.channels[index]
            let formatter = ChannelFormatter(unit: channel.unit, precision: Int(channel.decimals))
            return SelectionEntry(channel: id, trace: trace, series: series, formatter: formatter)
        }
    }

    /// Rebuild the readout grid: a row per selected channel (that has data), a
    /// column per selected lap, and each cell the channel's series sliced to that
    /// lap's `[startTimeS, endTimeS]` window — so a cursor outside a lap's range
    /// reads as extrapolated. A slice with no samples is omitted, leaving a
    /// no-data cell.
    private func rebuildReadoutTable() {
        let rows = selectionData.map(\.channel)
        let columns = selection.laps.selected
        var series: [CellKey: ChannelSeries] = [:]
        for entry in selectionData {
            for lap in columns {
                guard let bounds = lapByID[lap] else { continue }
                let slice = entry.series.windowed(from: bounds.startTimeS, through: bounds.endTimeS)
                guard !slice.xs.isEmpty else { continue }
                series[CellKey(channel: entry.channel, lap: lap)] = slice
            }
        }
        readoutTableCache = ReadoutTableModel(rows: rows, columns: columns, series: series)
    }

    /// Rebuild the track map: fold the current colour channel's cached series into
    /// the (constant) GPS racing line (issue 8.6). The line follows the trajectory;
    /// only the colour-by-channel re-aligns when the selection or colour channel
    /// changes.
    private func rebuildTrackMap() {
        let colorSeries = colorChannel.flatMap { id in
            selectionData.first { $0.channel == id }?.series
        }
        trackMapCache = TrackMapModel(track: gpsTrackPoints, colorSeries: colorSeries)
    }

    /// Rebuild the lap overlay (issue 8.7): a distance-aligned ``OverlayLap`` per
    /// selected lap, plus the reference lap's delta-t versus each other lap.
    private func rebuildOverlay() {
        let channel = overlayChannel
        guard let analysis, !channel.isEmpty else {
            overlayLapsCache = []
            overlayDeltasCache = [:]
            return
        }
        let selectedLaps = selection.laps.selected.compactMap { lapByID[$0] }
        overlayLapsCache = analysis.overlayLaps(channel: channel, laps: selectedLaps)

        var deltas: [DeltaPair: [DeltaSample]] = [:]
        if let referenceID = selection.laps.reference, let reference = lapByID[referenceID] {
            for lap in selectedLaps where lap.index != reference.index {
                let strip = analysis.deltaSeries(reference: reference, comparison: lap)
                guard !strip.isEmpty else { continue }
                deltas[DeltaPair(reference: referenceID, target: LapID(Int(lap.index)))] = strip
            }
        }
        overlayDeltasCache = deltas
    }
}
