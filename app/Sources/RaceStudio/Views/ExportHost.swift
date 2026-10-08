import SwiftUI
import AppKit
import RaceStudioCore

/// Hosts *Export Video with Overlay* on the analysis window (issue 9.14): the
/// menu command's state, the settings and progress sheets, and the question
/// before the window closes over this window's export.
///
/// The app's export publishes several times a second while it runs; this
/// follows only its state (`$state`), so the window's menus and panels are
/// not redrawn on every tick. Which sheet is up, and what this window owns,
/// is the window's ``ExportFlowModel``.
struct ExportHost: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @Environment(\.videoExport) private var videoExport
    let coordinator: VideoExportCoordinator
    @ObservedObject var flow: ExportFlowModel
    @ObservedObject var controller: VideoReviewController
    @ObservedObject var review: VideoReviewModel
    let video: VideoWorkspace
    let window: AnalysisWindowModel
    let analysis: AnalysisSession?
    @State private var hasTelemetry = false
    @State private var exportState: ExportProgressModel.State = .idle

    @ViewBuilder
    func body(content: Content) -> some View {
        if let progress = videoExport {
            hosted(content, progress: progress)
        } else {
            content
        }
    }

    private func hosted(_ content: Content, progress: ExportProgressModel) -> some View {
        content
            .onReceive(video.data.$telemetry) { hasTelemetry = $0 != nil }
            // `$state` fires as the state is about to change: read the new
            // state from the value it delivers, never from the model.
            .onReceive(progress.$state) { state in
                exportState = state
                if flow.owns(progress) { announce(state) }
                flow.exportChanged(to: state, progress: progress)
            }
            .focusedSceneValue(\.exportVideoAction, ExportVideoAction(availability: availability, open: open))
            // One sheet modifier; a new sheet comes up only once the last has
            // gone (`sheetDismissed`), so one is never swapped for another in place.
            .sheet(item: $flow.route, onDismiss: flow.sheetDismissed) { route in
                sheet(route, progress: progress)
                    .environment(\.theme, .raceStudio)
            }
            // A fallback for the hand-off: should `onDismiss` ever not fire
            // after a programmatic dismissal, the waiting sheet still comes up
            // once the old one has had time to go. `sheetDismissed` does
            // nothing when nothing waits, so the usual path is unaffected.
            .onChange(of: flow.route == nil) { isGone in
                guard isGone else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flow.sheetDismissed() }
            }
            // Re-evaluated whenever the export's state (mirrored above) or the
            // flow changes.
            .background(WindowCloseGuard(isActive: flow.guardsClose(progress: progress),
                                         shouldClose: { confirmClose($0, progress: progress) }))
            // Closing the session or the window mid-preparation writes nothing:
            // stop the preparation rather than start an export nobody sees.
            .onDisappear(perform: coordinator.cancelPreparation)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(_ route: ExportFlowModel.Route, progress: ExportProgressModel) -> some View {
        switch route {
        case .settings(let model):
            ExportSheet(model: model,
                        onExport: { export(model, progress: progress) },
                        onCancel: flow.dismiss,
                        onSyncFirst: syncFirst)
        case .progress:
            ExportProgressSheet(progress: progress, flow: flow,
                                cancelPreparation: coordinator.cancelPreparation)
        }
    }

    // MARK: - Actions

    private var availability: ExportCommandAvailability {
        .of(controller: controller, review: review, hasTelemetry: hasTelemetry,
            isExporting: exportState.isActive || flow.isBusy)
    }

    private func open() {
        guard availability.isEnabled else { return }
        coordinator.open(video: video, window: window, kart: app.library.kart(forSession: window.contentID))
    }

    private func export(_ model: ExportSheetModel, progress: ExportProgressModel) {
        coordinator.export(model, video: video,
                           session: ExportSessionContext(kart: app.library.kart(forSession: window.contentID),
                                                         metadata: window.session.metadata, analysis: analysis),
                           progress: progress)
    }

    /// *Sync First*: close the sheet and show the sync controls in Video + Data.
    private func syncFirst() {
        flow.dismiss()
        window.select(layout: .videoReview)
        controller.syncRequest += 1
    }

    /// Ask before the window closes over this window's export; a confirmed
    /// close cancels it — or its preparation — waits for it to clean up, then
    /// closes.
    private func confirmClose(_ nsWindow: NSWindow, progress: ExportProgressModel) -> Bool {
        guard flow.guardsClose(progress: progress) else { return true }
        guard ExportGuardAlert.confirmCancel(message: L10n.string(.exportCloseMessage),
                                             confirm: L10n.string(.exportCloseConfirm)) else { return false }
        coordinator.cancelPreparation()
        Task { @MainActor in
            await progress.cancelAndWait()
            nsWindow.close()
        }
        return false
    }

    /// Say the end of this window's export to VoiceOver users — here, not in
    /// the sheet, so an export whose sheet was hidden is announced too.
    private func announce(_ state: ExportProgressModel.State) {
        let message: String
        switch state {
        case .finished(let url): message = L10n.format(.exportProgressFinished, url.lastPathComponent)
        case .failed(let error): message = ExportProgressModel.userMessage(for: error).title
        case .idle, .running, .cancelling: return
        }
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
