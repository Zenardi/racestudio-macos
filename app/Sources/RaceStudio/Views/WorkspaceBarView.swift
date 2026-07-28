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
    /// The imported session video (issue 9.5): non-nil presents the ``VideoSyncView``
    /// sheet bound to this window's shared cursor.
    @State private var videoURL: URL?

    private var store: ProjectStore { ProjectStore(validator: FFIExpressionValidator()) }
    private var projectType: UTType { UTType(filenameExtension: ProjectStore.fileExtension) ?? .json }

    var body: some View {
        HStack(spacing: 12) {
            Button { openWorkspace() } label: { Label("Open Workspace…", systemImage: "folder") }
                .help("Open a saved .rsproj workspace")
            Button { saveWorkspace() } label: { Label("Save Workspace…", systemImage: "square.and.arrow.down") }
                .help("Save this workspace (layout, selection, math channels) to a .rsproj file")
            Divider().frame(height: 18)
            Button { importVideo() } label: { Label(L10n.string(.controlImportVideo), systemImage: "film") }
                .help("Play an external session video synced to the analysis cursor")
            Divider().frame(height: 18)
            StoryBoardView(
                board: StoryBoardModel(selection: model.selection.laps, laps: model.session.laps),
                onSetReference: { model.setReferenceLap($0) },
                onHide: { model.toggleLap($0) },
                onMove: { model.reorderSelectedLap(from: $0, to: $1) })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sheet(isPresented: videoSheetPresented) { videoSheet }
    }

    /// Presents / dismisses the video-sync sheet off the imported URL.
    private var videoSheetPresented: Binding<Bool> {
        Binding(get: { videoURL != nil }, set: { if !$0 { videoURL = nil } })
    }

    /// The video-sync sheet: the 9.5 player bound to the window's shared cursor,
    /// with a header + Done to close.
    @ViewBuilder private var videoSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string(.featureVideoSync)).font(.headline)
                Spacer()
                Button("Done") { videoURL = nil }
            }
            .padding(10)
            Divider()
            if let videoURL {
                VideoSyncView(cursor: model.linkedCursor, videoURL: videoURL)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    /// Opens a video file and binds it to this window's cursor (issue 9.5).
    private func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        videoURL = url
    }

    private func saveWorkspace() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = "Workspace.\(ProjectStore.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.save(
            model.projectDocument(mathChannels: mathManager.definitions, logSheet: logSheet.sheet), to: url)
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

    private func presentOpenFailure(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
        alert.informativeText = "The file isn’t a readable RaceStudio workspace, "
            + "or it was saved by a newer version."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
