import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// What the export draws the overlay from, besides the footage (issue 9.14):
/// the garage kart for the badge, the session's metadata, and the analysis
/// pump to load telemetry the HUD's doesn't sample.
struct ExportSessionContext {
    let kart: Kart?
    let metadata: SessionMetadata
    let analysis: AnalysisSession?
}

/// The analysis window's glue for *Export Video with Overlay* (issue 9.14):
/// it opens the export sheet on the window's footage and session, runs the
/// save panel, starts the app's export, and says which sheet is up.
///
/// It holds no rules. What the sheet offers and checks is
/// ``ExportSheetModel``'s; the progress, its states and its messages are
/// ``ExportProgressModel``'s; the overlay is drawn by the HUD's own renderer
/// (``VideoDataViewModel/exportOverlay(layout:kart:metadata:analysis:locale:)``)
/// — all in `RaceStudioCore`. This applies them to AppKit: probing the file,
/// `NSSavePanel`, the footage's security scope, Finder.
@MainActor
final class VideoExportCoordinator: ObservableObject {

    /// The sheet on screen.
    enum Route: Identifiable {
        /// The export's settings.
        case settings(ExportSheetModel)
        /// The running or ended export.
        case progress

        var id: String {
            switch self {
            case .settings: return "settings"
            case .progress: return "progress"
            }
        }
    }

    /// The sheet on screen, if any.
    @Published var route: Route?
    /// Why the export could not start, before any progress — shown in the
    /// progress sheet.
    @Published private(set) var failure: ExportUserMessage?
    /// Whether the export's overlay is being prepared (the telemetry loaded
    /// for its channels) before the first frame.
    @Published private(set) var isPreparing = false
    /// Whether the app's running — or last — export was started in this window.
    @Published private(set) var startedHere = false
    /// The exported file's name, for the progress sheet.
    private(set) var fileName = ""

    private let settingsStore = ExportSettingsStore(store: UserDefaultsKeyValueStore())

    // MARK: - Opening

    /// Probe the window's footage and open the sheet on it, with the last-used
    /// settings. A file that can't be read is said, not swallowed.
    func open(video: VideoWorkspace, window: AnalysisWindowModel) {
        guard let url = video.controller.videoURL else { return }
        Task {
            do {
                let footage = try await FootageProbe.probe(url)
                guard let input = video.data.exportSheetInput(
                    source: url, footage: footage, session: window.session,
                    selectedLaps: window.selection.laps.selected,
                    hasWorkspaceOverlay: window.videoOverlay != nil) else { return }
                failure = nil
                route = .settings(ExportSheetModel(input: input, preferences: settingsStore.load()))
            } catch {
                showFailure(ExportProgressModel.userMessage(for: OverlayExportError(mapping: error,
                                                                                    requiredBytes: 0)))
            }
        }
    }

    /// Close the sheet; a running export carries on.
    func dismiss() {
        route = nil
    }

    // MARK: - Exporting

    /// *Export…*: remember the settings, ask where to save, and start the
    /// export there with the chosen overlay. Cancelling the save panel keeps
    /// the sheet.
    func export(_ sheet: ExportSheetModel, video: VideoWorkspace, session: ExportSessionContext,
                progress: ExportProgressModel) {
        settingsStore.save(sheet.preferences)
        guard let destination = chooseDestination(suggesting: sheet.suggestedFileName) else { return }
        let plan: ExportPlan
        switch sheet.makePlan() {
        case .success(let made): plan = made
        case .failure(let error): showFailure(ExportProgressModel.userMessage(for: error)); return
        }
        let layout = sheet.layout(workspace: video.editor.layout)
        fileName = destination.lastPathComponent
        failure = nil
        startedHere = true
        isPreparing = true
        route = .progress
        Task {
            defer { isPreparing = false }
            do {
                guard let overlay = try await video.data.exportOverlay(
                    layout: layout, kart: session.kart, metadata: session.metadata,
                    analysis: session.analysis) else {
                    showFailure(ExportUserMessage(title: ExportCommandAvailability.unavailable(.noTelemetry).help(),
                                                  fix: L10n.string(.exportFixWriterFailed)))
                    return
                }
                run(plan, overlay: overlay, to: destination, progress: progress)
            } catch {
                showFailure(ExportProgressModel.userMessage(for: OverlayExportError(mapping: error,
                                                                                    requiredBytes: 0)))
            }
        }
    }

    /// Show the progress sheet again.
    func showProgress() {
        route = .progress
    }

    /// Put an ended export away.
    func finish(progress: ExportProgressModel) {
        progress.dismiss()
        failure = nil
        route = nil
    }

    // MARK: - Internals

    /// Start `plan` with `overlay` to `destination`, holding the footage's
    /// security scope until the export ends.
    private func run(_ plan: ExportPlan, overlay: ExportOverlay, to destination: URL,
                     progress: ExportProgressModel) {
        let exporter = OverlayVideoExporter()
        let source = plan.request.source
        let scoped = source.startAccessingSecurityScopedResource()
        isPreparing = false
        progress.start(exporter.export(plan, overlay: overlay, to: destination), to: destination,
                       cancel: { await exporter.cancel() })
        Task {
            await progress.wait()
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
    }

    /// The save panel: an `.mp4` named `suggestion`, or `nil` when cancelled.
    private func chooseDestination(suggesting suggestion: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string(.exportSheetTitle)
        panel.prompt = L10n.string(.exportSavePrompt)
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestion
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func showFailure(_ message: ExportUserMessage) {
        isPreparing = false
        failure = message
        route = .progress
    }
}
