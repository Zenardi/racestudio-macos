import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// The top bar of the analysis window (issue 8.13): Open/Save `.rsproj` workspace
/// commands and the ``StoryBoardView`` lap strip.
///
/// Save captures the window's selection + active layout + math channels into a
/// ``ProjectDocument`` (the 8.13 `projectDocument` mapping) and writes it via the
/// 5.4 `ProjectStore`; Open loads one and restores it back into the window. The bar
/// is thin — the mapping and the StoryBoard model live in `RaceStudioCore`.
struct WorkspaceBar: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var mathManager: MathChannelsManagerModel
    @ObservedObject var logSheet: LogSheetModel
    /// The window's video-review player (issue 9.6): the bar reads the attached
    /// footage off it when saving, and hands a loaded project's attachment back.
    @ObservedObject var video: VideoReviewController
    /// The overlay editor (issue 9.12): a save marks it clean, an open loads the
    /// project's overlay into it with a fresh history.
    @ObservedObject var overlayEditor: OverlayEditorModel
    /// What the last project open could not read, until dismissed.
    @State private var notice: ProjectLoadNotice?
    @State private var showsNoticeDetails = false

    private var store: ProjectStore { ProjectStore(validator: FFIExpressionValidator()) }
    private var projectType: UTType { UTType(filenameExtension: ProjectStore.fileExtension) ?? .json }

    var body: some View {
        HStack(spacing: 12) {
            Button { openWorkspace() } label: { Label("Open Workspace…", systemImage: "folder") }
                .help("Open a saved .rsproj workspace")
            Button { saveWorkspace() } label: { Label("Save Workspace…", systemImage: "square.and.arrow.down") }
                .help("Save this workspace (layout, selection, math channels) to a .rsproj file")
            Divider().frame(height: 18)
            Button { model.select(layout: .videoReview) }
                label: { Label(L10n.string(.featureVideoData), systemImage: "film") }
                .help("Watch the session video with its data — HUD, lap plot and track map")
            Divider().frame(height: 18)
            StoryBoardView(
                board: StoryBoardModel(selection: model.selection.laps, laps: model.session.laps),
                onSetReference: { model.setReferenceLap($0) },
                onHide: { model.toggleLap($0) },
                onMove: { model.reorderSelectedLap(from: $0, to: $1) })
            if let notice { noticeBadge(notice) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func saveWorkspace() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = "Workspace.\(ProjectStore.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The attached video (issue 9.6) is captured with the alignment in force,
        // so a trim made after attaching is what reopens.
        do {
            try store.save(
                model.projectDocument(mathChannels: mathManager.definitions, logSheet: logSheet.sheet,
                                      video: video.attachmentForSaving), to: url)
            overlayEditor.markSaved()
        } catch {
            presentSaveFailure(url)
        }
    }

    private func openWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let document: ProjectDocument
        do {
            document = try store.load(from: url)
        } catch {
            // Surface a corrupt / unsupported-version / unreadable .rsproj rather than
            // swallowing it — the store throws a typed `ProjectError`.
            presentOpenFailure(url)
            return
        }
        model.restore(from: document)
        // The overlay (issue 9.12) opens in the editor with a fresh history, and
        // whatever the load could not read is said, not dropped.
        overlayEditor.load(document.overlay)
        notice = ProjectLoadNotice(document: document)
        // Re-open the workspace's video (issue 9.6). A moved or deleted file leaves
        // the panel in a stated failure rather than aborting the load.
        if let attachment = document.video {
            Task { await video.restore(attachment,
                                       sessionStartEpoch: Double(model.session.metadata.datetimeUtc)) }
        }
        // The log sheet (issue 8.17) is owned outside the window like the math
        // channels, so reapply the loaded document's sheet here.
        logSheet.apply(document.logSheet)
        // Math channels are owned by the 8.8 manager; re-add each so the restored
        // workspace re-evaluates them against this session (skipping any already there).
        Task {
            for definition in document.mathChannels {
                _ = await mathManager.add(name: definition.name, unit: definition.unit,
                                          expression: definition.expression)
            }
        }
    }

    /// The load notice: a quiet badge with the count, its lines on click.
    private func noticeBadge(_ notice: ProjectLoadNotice) -> some View {
        HStack(spacing: 4) {
            Button { showsNoticeDetails.toggle() } label: {
                Label(notice.summary(), systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showsNoticeDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notice.details().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: 360, alignment: .leading)
            }
            Button { self.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
    }

    private func presentSaveFailure(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save “\(url.lastPathComponent)”"
        alert.informativeText = "The workspace could not be written there."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func presentOpenFailure(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
        alert.informativeText = "The file isn’t a readable RaceStudio workspace, "
            + "or it was saved by a newer version."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
