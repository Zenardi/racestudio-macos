import SwiftUI
import RaceStudioCore

/// The RaceStudio-3-style analysis window (issue 8.3): a left layout-selector
/// rail, a channels+laps side panel, a central panel host, and a bottom measures
/// bar, all sharing one window-level ``LinkedCursor``.
///
/// Deliberately **thin**: the layout/selection/cursor/measures logic all lives in
/// `RaceStudioCore.AnalysisWindowModel`, so this view only lays out the regions
/// and forwards taps/scrubs into the model. The Time/Distance layout reuses
/// ``TimeDistancePlotView``; the summary layout reuses ``SessionSummaryView``.
struct AnalysisWindowView: View {
    @StateObject private var model: AnalysisWindowModel
    @StateObject private var mathManager: MathChannelsManagerModel
    // The histogram + scatter panel knobs (issue 8.9), held at the window level so
    // they survive layout switches.
    @StateObject private var stats = StatsPanelsModel()
    // The Channels Report knobs (issue 8.10) — statistic, mode, selected row —
    // likewise held at the window level so they survive layout switches.
    @StateObject private var report = ChannelsReportModel()
    // The Split Times knobs (issue 8.11) — split count, editable layout, focus —
    // likewise held at the window level so they survive layout switches.
    @StateObject private var splitReport = SplitReportModel()
    // The Spectrum panel knob (issue 8.16) — the window function — likewise held at
    // the window level so the taper choice survives layout switches.
    @StateObject private var spectrum = SpectrumPanelModel()
    // The Log Sheet (issue 8.17) — user-authored session/setup metadata — owned at
    // the window level like the math-channels manager, so an edited sheet survives
    // layout switches and is captured into / restored from the project.
    @StateObject private var logSheet = LogSheetModel()
    // The live analysis pump the Split Times panel reads the per-lap base grid from
    // (issue 8.11); nil in a non-FFI build/preview, which then shows an empty report.
    private let analysis: AnalysisSession?

    init(viewModel: SessionViewModel) {
        _model = StateObject(wrappedValue: AnalysisWindowModel(viewModel: viewModel))
        analysis = viewModel.analysis
        // Back the Math Channels editor with the evaluator over the retained handle
        // (issue 8.8); a non-FFI build/preview falls back to a rejecting evaluator.
        _mathManager = StateObject(wrappedValue: MathChannelsManagerModel(
            evaluator: viewModel.evaluator ?? NoSessionEvaluator()))
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(model: model, mathManager: mathManager, logSheet: logSheet)
            Divider()
            HStack(spacing: 0) {
                LayoutRail(layouts: model.layouts, active: model.activeLayout) { model.select(layout: $0) }
                Divider()
                ChannelsLapsPanelView(model: model)
                    .frame(width: 240)
                Divider()
                VStack(spacing: 0) {
                    PanelHost(model: model, mathManager: mathManager, stats: stats,
                              report: report, splitReport: splitReport, spectrum: spectrum,
                              logSheet: logSheet, analysis: analysis)
                    Divider()
                    MeasuresBar(model: model, cursor: model.linkedCursor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel(L10n.string(.chartAnalysisWindow))
    }
}

// MARK: - Layout rail

/// The left rail: one button per layout, highlighting the active one.
private struct LayoutRail: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let layouts: [WindowLayout]
    let active: WindowLayout
    let onSelect: (WindowLayout) -> Void

    var body: some View {
        VStack(spacing: theme.spacing.xs) {
            ForEach(layouts) { layout in
                Button { onSelect(layout) } label: {
                    VStack(spacing: theme.spacing.xs) {
                        Image(systemName: layout.systemImageName).font(.token(theme.typography.headline))
                        Text(layout.title).font(.token(theme.typography.caption)).multilineTextAlignment(.center)
                    }
                    .frame(width: 64, height: 56)
                    // Active vs inactive is signalled by primary-vs-secondary text
                    // (both WCAG-AA proven on the canvas) plus the accent wash — the
                    // label itself is never drawn in `accent`, which is only proven
                    // at the ≥3:1 non-text bar, not the 4.5:1 a caption needs.
                    .foregroundStyle(layout == active
                        ? theme.palette.textPrimary.color(scheme)
                        : theme.palette.textSecondary.color(scheme))
                    .background(layout == active
                        ? theme.palette.accent.color(scheme).opacity(0.16)
                        : Color.clear)
                    .cornerRadius(theme.radius.sm)
                }
                .buttonStyle(.plain)
                .help(layout.title)
            }
            Spacer()
        }
        .padding(.vertical, theme.spacing.sm)
        .frame(width: 80)
    }
}

// MARK: - Central panel host

/// Swaps the central panel for the active layout, preserving the surrounding
/// selection/cursor state (owned by the model).
private struct PanelHost: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var mathManager: MathChannelsManagerModel
    @ObservedObject var stats: StatsPanelsModel
    @ObservedObject var report: ChannelsReportModel
    @ObservedObject var splitReport: SplitReportModel
    @ObservedObject var spectrum: SpectrumPanelModel
    @ObservedObject var logSheet: LogSheetModel
    let analysis: AnalysisSession?

    var body: some View {
        Group {
            switch model.activeLayout {
            case .timeDistance:
                if model.selection.isEmpty {
                    ContentUnavailableHint(text: "Select a channel to plot")
                } else {
                    TimeDistancePlotView(traces: model.traces, mode: .time,
                                         lapBoundaries: lapTimeBoundaries(model.session.laps))
                }
            case .channelTable:
                ChannelTablePanel(model: model, cursor: model.linkedCursor)
            case .trackMap:
                TrackMapPanel(model: model, cursor: model.linkedCursor)
            case .lapOverlay:
                LapOverlayPanel(model: model)
            case .histogram:
                HistogramPanel(model: model, stats: stats)
            case .scatter:
                ScatterPanel(model: model, stats: stats)
            case .spectrum:
                SpectrumPanel(model: model, spectrum: spectrum, analysis: analysis)
            case .suspension:
                SuspensionPanel(model: model, stats: stats, spectrum: spectrum,
                                logSheet: logSheet, analysis: analysis)
            case .channelsReport:
                ChannelsReportPanel(model: model, report: report)
            case .splitTimes:
                SplitTimesPanel(model: model, report: splitReport, analysis: analysis)
            case .mathChannels:
                MathChannelsPanel(manager: mathManager, channelNames: model.session.channels.map(\.name))
            case .summary:
                SessionSummaryView(viewModel: SessionSummaryViewModel(session: model.session))
            case .logSheet:
                LogSheetPanel(model: logSheet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Channel table / measures panel (issue 8.5)

/// Hosts the reused ``ChannelTableView`` bound to the shared cursor: it observes
/// ``LinkedCursor`` so the value-at-cursor readouts re-render as the cursor moves,
/// while the channels × selected-laps grid (and its per-lap extrapolation) is
/// derived in `RaceStudioCore.AnalysisWindowModel`. Tapping a channel name pins
/// it as a large readout; tapping a lap header makes it the reference the row
/// deltas are measured against.
private struct ChannelTablePanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        if model.readoutTable.rows.isEmpty || model.readoutTable.columns.isEmpty {
            ContentUnavailableHint(text: "Select channels and laps to compare")
        } else {
            ScrollView([.horizontal, .vertical]) {
                ChannelTableView(model: model.readoutTable,
                                 cursorX: cursor.timePosition,
                                 formatters: model.channelFormatters,
                                 pinned: model.pinnedChannels,
                                 referenceLap: model.selection.laps.reference,
                                 onPin: { model.togglePinned($0) },
                                 onSetReference: { model.setReferenceLap($0) })
            }
        }
    }
}

// MARK: - Track map panel (issue 8.6)

/// Hosts the reused ``TrackMapView`` bound to the shared cursor both ways: it
/// observes ``LinkedCursor`` so the position marker follows every cursor move
/// (``AnalysisWindowModel/gpsCursorIndex``), and a hover / click on the map drives
/// the window's cursor (``AnalysisWindowModel/moveTrackCursor(toFix:)``). A colour
/// picker chooses which selected channel colours the line, and a stepper sets the
/// sector count; the racing line, its colour-by-channel, the colour scale, and the
/// nearest-fix mapping are all derived in `RaceStudioCore`.
private struct TrackMapPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    // Observed so the position marker (`gpsCursorIndex`, read in the binding below)
    // re-renders on every cursor move — do not remove even though `body` reads it
    // only through the model.
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        let map = model.trackMap
        if map.coordinates.isEmpty {
            ContentUnavailableHint(text: "No GPS data for this session")
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                TrackMapView(coords: map.coordinates,
                             distances: map.distances,
                             channelValues: map.channelValues,
                             colorScale: map.colorScale,
                             lapDistance: map.lapDistance,
                             sectorSplits: model.sectorSplits,
                             cursorIndex: Binding(
                                get: { model.gpsCursorIndex },
                                set: { if let index = $0 { model.moveTrackCursor(toFix: index) } }))
                    .padding(8)
            }
        }
    }

    /// Colour-by-channel picker (over the selected channels) + sector-count stepper.
    private var controls: some View {
        HStack(spacing: 16) {
            if !model.selection.channels.isEmpty {
                Picker("Colour", selection: Binding(
                    get: { model.colorChannel },
                    set: { if let channel = $0 { model.setColorChannel(channel) } })) {
                    ForEach(model.selection.channels, id: \.self) { channel in
                        Text(channel.name).tag(Optional(channel))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Stepper("Sectors: \(model.sectorSplits)", value: Binding(
                get: { model.sectorSplits },
                set: { model.setSectorSplits($0) }), in: 0...12)
                .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Lap overlay panel (issue 8.7)

/// Hosts the reused lap-overlay comparison surface bound to the window's shared
/// lap selection: the overlaid distance-mode plot (``TimeDistancePlotView``) for
/// the overlay channel — one colour per lap — and the reused ``DeltaStripView``
/// showing the predictive gain/loss versus the reference lap. Trace building,
/// colouring, and delta interpolation all come from
/// `RaceStudioCore.LapOverlayViewModel`; tapping a lap in the legend makes it the
/// reference. The strip's distance scrub cursor is local pending a shared distance
/// basis (deferred, as in 8.3).
private struct LapOverlayPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @State private var cursorDistance: Double?
    /// Local-time alignment (issue 8.12): when on, laps overlay on the time axis
    /// aligned to a common start so identical track sections line up; when off,
    /// they overlay on the shared distance basis (the 8.7 default).
    @State private var localTime = false

    var body: some View {
        let laps = model.overlayLaps
        if model.overlayChannel.isEmpty {
            ContentUnavailableHint(text: "Select a channel to overlay")
        } else if laps.count < 2 {
            ContentUnavailableHint(text: "Select at least two laps to overlay")
        } else {
            let overlay = LapOverlayViewModel(selection: model.selection.laps,
                                              laps: laps, deltas: model.overlayDeltas)
            let traces = localTime ? overlay.localTimeTraces(for: model.overlayChannel)
                                   : overlay.traces(for: model.overlayChannel)
            VStack(spacing: 4) {
                legend(overlay)
                TimeDistancePlotView(traces: traces,
                                     mode: localTime ? .time : .distance, renderer: .swiftCharts,
                                     seriesColors: seriesColors(overlay))
                deltaStrip(overlay)
            }
            .padding(8)
        }
    }

    /// The lap → line colour map (keyed by lap label = trace name) so the plotted
    /// lines match the legend swatches instead of Swift Charts' default palette.
    private func seriesColors(_ overlay: LapOverlayViewModel) -> [String: Color] {
        var colors: [String: Color] = [:]
        for lap in model.overlayLaps { colors[lap.label] = Color(overlay.colorForLap(lap.id)) }
        return colors
    }

    /// The lap legend: a colour swatch + label per overlaid lap; tapping one makes
    /// it the reference the delta strip is measured against.
    private func legend(_ overlay: LapOverlayViewModel) -> some View {
        HStack(spacing: 14) {
            Text(model.overlayChannel).font(.caption.bold())
            ForEach(model.overlayLaps, id: \.id) { lap in
                Button { model.setReferenceLap(lap.id) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(overlay.colorForLap(lap.id))).frame(width: 9, height: 9)
                        Text(lap.label).font(.caption)
                        if model.selection.laps.reference == lap.id {
                            Text("REF").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.selection.laps.reference == lap.id ? "Reference lap" : "Set as reference lap")
            }
            Spacer()
            Toggle("Local time", isOn: $localTime)
                .toggleStyle(.switch)
                .fixedSize()
                .help("Align laps to a common start so identical track sections line up")
        }
    }

    /// The predictive gain/loss strip of the comparison target versus the reference
    /// lap, scrubbable to read the Δt at the cursor.
    @ViewBuilder
    private func deltaStrip(_ overlay: LapOverlayViewModel) -> some View {
        if let reference = model.selection.laps.reference, let target = model.selection.laps.comparisonTarget {
            let strip = overlay.deltaStrip(reference: reference, target: target)
            // A pair the core couldn't compute yields an empty strip — omit it
            // rather than render an empty band.
            if !strip.isEmpty {
                DeltaStripView(
                    strip: strip,
                    readout: cursorDistance.flatMap {
                        overlay.readout(in: strip, at: $0, reference: reference, target: target)
                    },
                    cursorDistance: $cursorDistance)
            }
        }
    }
}

/// A centered, designed placeholder shown when a panel has nothing to render —
/// a brand-tokenized empty state (issue 7.5) shared across the window's panels
/// (issues 8.3 / 8.9), so "nothing selected yet" reads as intentional, not blank.
struct ContentUnavailableHint: View {
    let text: String
    var symbol: String = "square.dashed"
    var body: some View {
        BrandStateView(symbol: symbol, title: text)
    }
}

// The bottom measures bar (scrubber + value-at-cursor) lives in `MeasuresBar.swift`.
