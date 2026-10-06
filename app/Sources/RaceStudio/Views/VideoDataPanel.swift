import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// The analysis window's **Video + Data** workspace (issue 9.12; it replaced
/// the 9.6 Video Review panel): the synced footage with a live telemetry HUD,
/// the lap strip plot under it, and the track map over the lap × sector grid —
/// all on one clock. Play the footage and everything follows it; scrub the
/// plot or click the map while paused and the footage follows. The same panel
/// hosts the overlay editor.
///
/// Deliberately thin, as every panel in this window is. The clock, the frames,
/// the lap picks and *Play lap* (``VideoDataViewModel``), the review windows and
/// sync (``VideoReviewModel``), the editor (``OverlayEditorModel``) and the pane
/// layout (``VideoDataPaneLayout``) all live in `RaceStudioCore`; this view lays
/// the regions out, forwards clicks, and lets ``VideoReviewController`` apply
/// the decisions to AVKit. It does not observe the data model or the cursor —
/// they change every frame — only its children that draw them do. It does
/// observe the editor and the pane layout, so it redraws while a widget or a
/// divider is dragged, not while the footage plays.
struct VideoDataPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.undoManager) private var undoManager
    @ObservedObject var model: AnalysisWindowModel
    let data: VideoDataViewModel
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var editor: OverlayEditorModel
    @ObservedObject var splitReport: SplitReportModel
    let cursor: LinkedCursor
    @ObservedObject var controller: VideoReviewController
    let analysis: AnalysisSession?

    /// The whole-session base grid, read once per base resolution (as the 8.11
    /// panel reads it) and re-cut into absolute windows by the timeline.
    @State private var segments: [LapSegments] = []
    @State private var loadedBase: Int?
    @State private var isEditing = false
    @State private var showsSync = true
    @State private var presets: [OverlayLayout] = []
    /// Mirrors whether the telemetry is in, so the panel redraws once it lands.
    @State private var hasTelemetry = false

    var body: some View {
        Group {
            if model.session.laps.isEmpty {
                ContentUnavailableHint(text: L10n.string(.videoNoLaps), symbol: "film")
            } else {
                workspace
            }
        }
        .onAppear(perform: appear)
        .onDisappear {
            // Undo is scoped to the panel: ⌘Z elsewhere never edits a HUD out of sight.
            editor.resetHistory()
        }
        .onChange(of: splitReport.layout) { _ in
            rebuildTimeline()
            reloadTelemetryIfNeeded()
        }
        .onChange(of: editor.layout.sessionChannelNames) { _ in reloadTelemetryIfNeeded() }
        .onChange(of: undoManager) { editor.undoManager = $0 }
        .onReceive(cursor.$timePosition) { controller.seekFromCursor(to: $0) }
        .onReceive(data.$telemetry) { hasTelemetry = $0 != nil }
        .focusedSceneValue(\.videoDataActions, actions)
    }

    // MARK: - Layout

    private var workspace: some View {
        VStack(spacing: 0) {
            header
            if showsSync, controller.attachment != nil {
                VideoSyncBar(review: review, controller: controller, analysis: analysis)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            FractionSplit(axis: .horizontal, divider: .side, panes: $model.videoDataPanes, showsLeading: true,
                          showsTrailing: isEditing || model.videoDataPanes.showsSideColumn) {
                FractionSplit(axis: .vertical, divider: .plot, panes: $model.videoDataPanes, showsLeading: true,
                              showsTrailing: model.videoDataPanes.isVisible(.plot)) {
                    playerColumn
                } trailing: {
                    LapStripPlotView(data: data, cursor: cursor, units: editor.layout.units, onScrub: scrub)
                }
            } trailing: {
                sideColumn
            }
        }
    }

    private var playerColumn: some View {
        VStack(spacing: 0) {
            if controller.attachment == nil {
                attachPrompt
            } else {
                VideoDataPlayer(data: data, editor: editor, player: controller.player, isEditing: isEditing,
                                kart: kart, metadata: model.session.metadata)
            }
            Divider()
            VideoDataTransport(review: review, controller: controller, data: data, cursor: cursor,
                               goToSelection: controller.goToSelection)
        }
    }

    @ViewBuilder private var sideColumn: some View {
        if isEditing {
            OverlayEditorInspector(editor: editor, presets: presets, availability: availability)
        } else {
            FractionSplit(axis: .vertical, divider: .map, panes: $model.videoDataPanes,
                          showsLeading: model.videoDataPanes.isVisible(.map),
                          showsTrailing: model.videoDataPanes.isVisible(.lapList)) {
                VideoDataMapPane(data: data, cursor: cursor, onSeek: scrub)
            } trailing: {
                VideoSectorGrid(review: review, onSelectLap: selectLap, onSelectSector: selectSector)
            }
        }
    }

    /// Nothing attached yet: a designed prompt where the footage goes — the
    /// telemetry panes work without it.
    private var attachPrompt: some View {
        BrandStateView(
            symbol: "film",
            title: L10n.string(.featureVideoData),
            message: controller.loadFailure ?? L10n.string(.videoAttachPrompt),
            actionLabel: L10n.string(.controlImportVideo),
            action: pickVideo)
    }

    // MARK: - Header

    /// The attached file, the pane and HUD toggles, and the sync controls'
    /// switch (issue 9.7's bar stays one click away).
    private var header: some View {
        HStack(spacing: 10) {
            Label(controller.attachment?.displayName ?? L10n.string(.featureVideoData), systemImage: "film")
                .lineLimit(1)
            Spacer()
            Toggle(L10n.string(.videoPanePlot), isOn: paneBinding(.plot))
            Toggle(L10n.string(.videoPaneMap), isOn: paneBinding(.map))
            Toggle(L10n.string(.videoPaneLaps), isOn: paneBinding(.lapList))
            Divider().frame(height: 16)
            Toggle(L10n.string(.controlShowHUD), isOn: Binding(
                get: { editor.layout.isEnabled }, set: { editor.setShowsHUD($0) }))
                .help(L10n.string(.controlShowHUD) + " (⇧⌘H)")
            Toggle(isEditing ? L10n.string(.controlDoneEditing) : L10n.string(.controlEditOverlay), isOn: $isEditing)
                .help(L10n.string(.controlEditOverlay) + " (⇧⌘E)")
            Divider().frame(height: 16)
            if controller.attachment != nil {
                Toggle(L10n.string(.controlSyncControls), isOn: $showsSync)
            }
            Button(L10n.string(.controlImportVideo), action: pickVideo)
            if controller.attachment != nil {
                Button(L10n.string(.controlRemoveVideo)) { controller.removeVideo() }
            }
        }
        .toggleStyle(.button)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func paneBinding(_ pane: VideoDataPane) -> Binding<Bool> {
        Binding(get: { model.videoDataPanes.isVisible(pane) },
                set: { model.videoDataPanes.setVisible($0, for: pane) })
    }

    // MARK: - Session facts

    private var kart: Kart? { app.library.kart(forSession: model.contentID) }

    private var availability: [OverlayWidget.ID: WidgetAvailability] {
        guard hasTelemetry, let context = data.overlayContext(kart: kart, metadata: model.session.metadata) else {
            return [:]
        }
        return editor.layout.availability(for: context)
    }

    private var actions: VideoDataActions {
        VideoDataActions(playLap: { if !controller.playLap() { NSSound.beep() } },
                         toggleLoop: { review.loops.toggle() },
                         toggleHUD: { editor.setShowsHUD(!editor.layout.isEnabled) },
                         toggleEditing: { isEditing.toggle() },
                         loops: review.loops, showsHUD: editor.layout.isEnabled, isEditing: isEditing)
    }

    // MARK: - Actions

    private func appear() {
        controller.start(driving: cursor)
        editor.undoManager = undoManager
        presets = OverlayPresetStore().presets()
        data.setTrack(model.gpsTrack)
        rebuildTimeline()
        // Catches a split or overlay change made while the panel was off screen.
        reloadTelemetryIfNeeded()
        controller.seekFromCursor(to: cursor.timePosition)
    }

    private func selectLap(_ lap: LapID) {
        data.selectLap(lap)
        controller.goToSelection()
    }

    private func selectSector(_ sector: SectorSpan) {
        data.selectSector(sector)
        controller.goToSelection()
    }

    /// A scrub of the plot or a click on the map: stop playback first, so the
    /// footage follows the cursor there (only a paused player does).
    private func scrub(to time: Double) {
        controller.pauseForScrub()
        cursor.moveTime(time)
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The cursor's time extent is the session's length — what a file-date
        // guess must overlap to be proposed (issue 9.7).
        Task { await controller.attach(url, sessionStartEpoch: Double(model.session.metadata.datetimeUtc),
                                       sessionDuration: cursor.timeBounds?.upperBound ?? 0) }
    }

    /// (Re)load the telemetry the HUD, the plot and the map read — timed against
    /// the review's laps and sectors, with the overlay's named channels — when
    /// it is not in yet or was loaded for other ones.
    private func reloadTelemetryIfNeeded() {
        let channels = editor.layout.sessionChannelNames
        guard let analysis, data.needsTelemetryReload(channels: channels) else { return }
        Task { await data.loadTelemetry(from: analysis, channels: channels) }
    }

    /// Re-cut the lap/sector windows for the current split layout (the 8.11
    /// split-count control), so the grid, the map's marks and the Split Times
    /// table stay in step. Returns whether the timeline changed.
    @discardableResult
    private func rebuildTimeline() -> Bool {
        if loadedBase != splitReport.layout.base {
            segments = analysis?.segmentTimes(splits: splitReport.layout.base) ?? []
            loadedBase = splitReport.layout.base
        }
        let timeline = LapSectorTimeline.make(laps: model.session.laps, segments: segments,
                                              layout: splitReport.layout)
        guard timeline != review.timeline else { return false }
        review.update(timeline: timeline)
        return true
    }
}
