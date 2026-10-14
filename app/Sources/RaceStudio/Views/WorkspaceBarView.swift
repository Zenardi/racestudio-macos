import SwiftUI
import RaceStudioCore

/// The top bar of the analysis window (issue 8.13): the Video + Data shortcut,
/// the ``StoryBoardView`` lap strip, and what the session's workspace has to
/// say (issue 9.20) — what its open could not read, and a save that failed.
///
/// The workspace saves itself (``WorkspaceAutosave``), so the bar has no Open or
/// Save. It is thin — the StoryBoard model and the autosave live in
/// `RaceStudioCore`.
struct WorkspaceBar: View {
    @ObservedObject var model: AnalysisWindowModel
    /// The session's workspace: its load notice and its save state.
    @ObservedObject var workspace: WorkspaceAutosave
    @State private var showsNoticeDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Button { model.select(layout: .videoReview) }
                label: { Label(L10n.string(.featureVideoData), systemImage: "film") }
                .help(L10n.string(.videoHelpWorkspaceButton))
            Divider().frame(height: 18)
            StoryBoardView(
                board: StoryBoardModel(selection: model.selection.laps, laps: model.session.laps),
                onSetReference: { model.setReferenceLap($0) },
                onHide: { model.toggleLap($0) },
                onMove: { model.reorderSelectedLap(from: $0, to: $1) })
            if let notice = workspace.notice { noticeBadge(notice) }
            if workspace.saveFailed {
                Label(L10n.string(.workspaceSaveFailed), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            Button { workspace.dismissNotice() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string(.controlDismiss))
        }
    }
}
