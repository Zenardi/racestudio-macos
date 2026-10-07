import SwiftUI
import AppKit
import RaceStudioCore

/// Hosts *Export Video with Overlay* on the analysis window (issue 9.14): the
/// menu command's state, the settings and progress sheets, the progress
/// sheet's return when an export it hid ends, and the question before the
/// window closes mid-export.
///
/// A modifier, so the app's export — which publishes several times a second
/// while it runs — redraws only this, never the window's panels.
struct ExportHost: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var progress: ExportProgressModel
    @ObservedObject var coordinator: VideoExportCoordinator
    @ObservedObject var controller: VideoReviewController
    @ObservedObject var review: VideoReviewModel
    let video: VideoWorkspace
    let window: AnalysisWindowModel
    let analysis: AnalysisSession?
    @State private var hasTelemetry = false

    func body(content: Content) -> some View {
        content
            .onReceive(video.data.$telemetry) { hasTelemetry = $0 != nil }
            .focusedSceneValue(\.exportVideoAction, ExportVideoAction(availability: availability, open: open))
            .sheet(item: $coordinator.route) { route in
                sheet(route)
                    .environment(\.theme, .raceStudio)
                    .environmentObject(progress)
            }
            .onChange(of: progress.state) { state in
                // An export ending while its sheet is hidden brings the result back.
                guard coordinator.startedHere, coordinator.route == nil else { return }
                switch state {
                case .finished, .failed: coordinator.showProgress()
                case .idle, .running, .cancelling: break
                }
            }
            .background(WindowCloseGuard(isActive: coordinator.startedHere && progress.isActive,
                                         shouldClose: confirmClose))
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(_ route: VideoExportCoordinator.Route) -> some View {
        switch route {
        case .settings(let model):
            ExportSheet(model: model,
                        onExport: { export(model) },
                        onCancel: coordinator.dismiss,
                        onSyncFirst: syncFirst)
        case .progress:
            ExportProgressSheet(progress: progress, coordinator: coordinator)
        }
    }

    // MARK: - Actions

    private var availability: ExportCommandAvailability {
        .of(controller: controller, review: review, hasTelemetry: hasTelemetry, progress: progress)
    }

    private func open() {
        guard availability.isEnabled else { return }
        coordinator.open(video: video, window: window)
    }

    private func export(_ model: ExportSheetModel) {
        coordinator.export(model, video: video,
                           session: ExportSessionContext(kart: app.library.kart(forSession: window.contentID),
                                                         metadata: window.session.metadata, analysis: analysis),
                           progress: progress)
    }

    /// *Sync First*: close the sheet and show the sync controls in Video + Data.
    private func syncFirst() {
        coordinator.dismiss()
        window.select(layout: .videoReview)
        controller.syncRequest += 1
    }

    /// Ask before the window closes mid-export; a confirmed close cancels the
    /// export, waits for it to clean up, then closes.
    private func confirmClose(_ nsWindow: NSWindow) -> Bool {
        guard progress.isActive else { return true }
        guard ExportGuardAlert.confirmCancel(message: L10n.string(.exportCloseMessage),
                                             confirm: L10n.string(.exportCloseConfirm)) else { return false }
        Task { @MainActor in
            await progress.cancelAndWait()
            nsWindow.close()
        }
        return false
    }
}
