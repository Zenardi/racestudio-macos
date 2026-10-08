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

/// The analysis window's AppKit glue for *Export Video with Overlay* (issue
/// 9.14): probing the footage, `NSSavePanel`, the footage's security scope,
/// and starting the app's export.
///
/// It holds no rules. Which sheet is up and what this window owns is
/// ``ExportFlowModel``'s; what the sheet offers and checks is
/// ``ExportSheetModel``'s; the progress and its messages are
/// ``ExportProgressModel``'s; the overlay is drawn by the HUD's own renderer
/// (``VideoDataViewModel/exportOverlay(layout:kart:metadata:analysis:locale:)``)
/// — all in `RaceStudioCore`.
@MainActor
final class VideoExportCoordinator: ObservableObject {

    /// The window's part in the app's export — what the sheets observe.
    let flow = ExportFlowModel()

    private let settingsStore = ExportSettingsStore(store: UserDefaultsKeyValueStore())
    /// The preparation under way — the overlay's telemetry loading — so a
    /// cancel can stop it.
    private var preparation: Task<Void, Never>?

    // MARK: - Opening

    /// Probe the window's footage and open the sheet on it with the last-used
    /// settings — listing the overlay's widgets against what the session, and
    /// its garage `kart`, can feed. Ignored while one is opening or a sheet is
    /// up; a file that can't be read is said, not swallowed.
    func open(video: VideoWorkspace, window: AnalysisWindowModel, kart: Kart?) {
        guard let url = video.controller.videoURL, flow.beginOpening() else { return }
        Task {
            do {
                let footage = try await Self.withAccess(to: url) { try await FootageProbe.probe(url) }
                guard let input = video.data.exportSheetInput(
                    source: url, footage: footage, session: window.session,
                    selectedLaps: window.selection.laps.selected,
                    workspaceOverlay: window.videoOverlay != nil ? video.editor.layout : nil, kart: kart) else {
                    flow.failed(ExportProgressModel.telemetryMissingMessage())
                    return
                }
                flow.opened(ExportSheetModel(input: input, preferences: settingsStore.load()))
            } catch {
                flow.failed(ExportProgressModel.userMessage(for: OverlayExportError(mapping: error,
                                                                                    requiredBytes: 0)))
            }
        }
    }

    // MARK: - Exporting

    /// *Export…*: remember the settings, ask where to save, and prepare and
    /// start the export there with the chosen overlay. Cancelling the save
    /// panel keeps the sheet.
    func export(_ sheet: ExportSheetModel, video: VideoWorkspace, session: ExportSessionContext,
                progress: ExportProgressModel) {
        settingsStore.save(sheet.preferences)
        guard let destination = chooseDestination(suggesting: sheet.suggestedFileName) else { return }
        let plan: ExportPlan
        switch sheet.makePlan() {
        case .success(let made): plan = made
        case .failure(let error): flow.failed(ExportProgressModel.userMessage(for: error)); return
        }
        guard let begun = flow.beginExport(to: destination, progress: progress) else { return }
        let layout = sheet.layout()
        preparation = Task {
            do {
                let overlay = try await video.data.exportOverlay(layout: layout, kart: session.kart,
                                                                 metadata: session.metadata,
                                                                 analysis: session.analysis)
                // A preparation cancelled — or since replaced by another
                // export — starts nothing, however late it returns.
                guard flow.endPreparation(begun) else { return }
                guard let overlay else { return flow.failed(ExportProgressModel.telemetryMissingMessage()) }
                run(plan, overlay: overlay, to: destination, progress: progress)
            } catch {
                flow.failPreparation(begun, ExportProgressModel.userMessage(for: OverlayExportError(
                    mapping: error, requiredBytes: 0)))
            }
        }
    }

    /// Cancel the export still being prepared: nothing is written.
    func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
        flow.cancelPreparation()
    }

    // MARK: - Internals

    /// Start `plan` with `overlay` to `destination`, holding the footage's
    /// security scope until the export ends. An exporter's stream starts its
    /// export as soon as it is made, so it is made only once the app's export
    /// is known to be free.
    private func run(_ plan: ExportPlan, overlay: ExportOverlay, to destination: URL,
                     progress: ExportProgressModel) {
        guard !progress.isActive else { return flow.failed(ExportProgressModel.exportRunningMessage()) }
        let exporter = OverlayVideoExporter()
        let source = plan.request.source
        let scoped = source.startAccessingSecurityScopedResource()
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

    /// Run `body` holding `url`'s security scope — a workspace video reopened
    /// from its bookmark is readable only inside it.
    private static func withAccess<T>(to url: URL, _ body: () async throws -> T) async rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await body()
    }
}
