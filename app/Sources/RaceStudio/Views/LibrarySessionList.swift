import SwiftUI
import RaceStudioCore

/// The library browser's sessions list, with the per-row actions: double-click to
/// open for analysis, Return or the context menu to rename, and Delete to remove —
/// through a confirmation that separates forgetting the row from deleting
/// RaceStudio's copy of the file.
///
/// Extracted from ``LibraryBrowserView`` so each type stays inside the lint's
/// body-length budget. Thin, like the rest of the shell: every decision (what is
/// visible, what a name resolves to, whether a copy can be discarded) comes from
/// `RaceStudioCore.LibraryBrowserModel`.
///
/// **Double-click opens** rather than renames. The user asked for both on this
/// list, which cannot both be the double-click; opening is the far more frequent
/// action and is the macOS convention, so renaming takes Return and the context
/// menu — the Finder arrangement.
struct LibrarySessionList: View {
    @ObservedObject var library: LibraryBrowserModel
    let onOpen: (SessionSummary) -> Void
    let onImport: () -> Void
    /// Start renaming — the sheet is owned by ``LibraryBrowserView`` so the list's
    /// context menu and the preview pane's buttons drive the same one.
    let onRename: (RenameTarget) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// The session awaiting delete confirmation.
    @State private var deleting: SessionSummary?
    /// Set when discarding a copy failed, so the user is told rather than left
    /// believing a file was deleted that wasn't.
    @State private var deleteFailed = false

    var body: some View {
        List(selection: idSelection) {
            ForEach(library.sessions) { summary in
                SessionListRow(summary: summary)
                    .tag(summary.id)
                    .draggable(summary.id)  // drag into a manual collection to curate it
                    // A simultaneous gesture so the double-click does not swallow
                    // the single click the List needs for selection.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        guard summary.isAvailable else { return }
                        onOpen(summary)
                    })
                    .contextMenu { rowMenu(summary) }
            }
        }
        .overlay { if library.sessions.isEmpty { emptyState } }
        .onDeleteCommand { deleting = library.selectedSummary }
        .confirmationDialog(deleteTitle, isPresented: deletePresented, presenting: deleting) { summary in
            deleteActions(summary)
        } message: { summary in
            Text(deleteMessage(summary))
        }
        .alert("Couldn’t delete the file", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The session was removed from the library, but RaceStudio couldn’t "
                 + "delete its copy of the file.")
        }
    }

    // MARK: - Row menu

    @ViewBuilder
    private func rowMenu(_ summary: SessionSummary) -> some View {
        Button("Open in Analysis") { onOpen(summary) }
            .disabled(!summary.isAvailable)
        Button("Rename Session…") { onRename(.session(summary)) }
        if summary.trackID != nil {
            Button("Rename Track…") { onRename(.track(summary)) }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = summary }
    }

    // MARK: - Delete confirmation

    private var deleteTitle: String {
        deleting.map { "Delete “\($0.displayTitle)”?" } ?? "Delete session?"
    }

    private func deleteMessage(_ summary: SessionSummary) -> String {
        library.canDiscardCopy(id: summary.id)
            ? "Removing it from the library keeps RaceStudio’s copy of the file on "
                + "disk. Your original file is never deleted either way."
            : "This session is removed from the library. The file it was imported "
                + "from is left untouched."
    }

    @ViewBuilder
    private func deleteActions(_ summary: SessionSummary) -> some View {
        Button("Remove from Library", role: .destructive) { delete(summary, .removeFromLibrary) }
        if library.canDiscardCopy(id: summary.id) {
            Button("Remove and Delete Copy", role: .destructive) { delete(summary, .discardingCopy) }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func delete(_ summary: SessionSummary, _ deletion: SessionDeletion) {
        do {
            try library.delete(id: summary.id, deletion)
        } catch {
            // The row is always removed first, so only the file step can fail here.
            deleteFailed = true
        }
    }

    // MARK: - Bindings

    private var idSelection: Binding<String?> {
        Binding(get: { library.selectedID }, set: { library.select($0) })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var emptyState: some View {
        BrandStateView(symbol: "tray",
                       title: "No sessions",
                       message: "Import a .xrk, .xrz, or .csv file to get started.",
                       actionLabel: "Import…", action: onImport)
    }
}

/// One row of the sessions list: title, recorded date, vehicle/driver, lap count.
private struct SessionListRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
            HStack {
                Text(summary.displayTitle)
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                if !summary.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.palette.negative.color(scheme))
                        .help("The source file is missing or moved")
                }
            }
            // The logger's own wall clock, not the reader's zone — see `SessionDate`.
            Text(SessionDate.text(summary.date))
                .font(.token(theme.typography.caption))
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
            HStack(spacing: theme.spacing.xs + 2) {
                Text(summary.vehicle)
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                if !summary.driver.isEmpty {
                    Text("• \(summary.driver)")
                        .font(.token(theme.typography.caption))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                }
                Spacer()
                Text("\(summary.lapCount) lap\(summary.lapCount == 1 ? "" : "s")")
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
        }
        .padding(.vertical, theme.spacing.xs / 2)
    }
}

/// What a rename sheet is editing: the name of one session, or the name of the
/// circuit it was recorded at.
///
/// Naming the **track** is the fix for a logger that stamps the venue
/// inconsistently — it retitles every session recorded there, including ones
/// imported later — while naming the **session** labels just that one outing.
enum RenameTarget: Identifiable {
    /// Rename this one session.
    case session(SessionSummary)
    /// Rename the circuit this session was recorded at.
    case track(SessionSummary)

    var id: String {
        switch self {
        case .session(let summary): return "session-\(summary.id)"
        case .track(let summary): return "track-\(summary.trackID ?? summary.id)"
        }
    }

    var summary: SessionSummary {
        switch self {
        case .session(let summary), .track(let summary): return summary
        }
    }

    var isTrack: Bool {
        if case .track = self { return true }
        return false
    }
}

/// The rename sheet, for a session or a track. Whatever name is currently in
/// effect is shown as the placeholder, so clearing the field visibly restores it.
struct SessionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let target: RenameTarget
    /// The circuit's current user-chosen name, when renaming a track.
    let currentTrackName: String?
    let onCommit: (String) -> Void
    @State private var name: String = ""

    /// What the name falls back to when the field is left empty.
    private var fallback: String {
        let summary = target.summary
        if target.isTrack { return summary.trackLabel ?? summary.venue }
        return summary.venue.isEmpty ? SessionSummary.untitledText : summary.venue
    }

    private var hint: String {
        let named = fallback.isEmpty ? "." : " (\u{201C}\(fallback)\u{201D})."
        return target.isTrack
            ? "Applies to every session recorded at this track. Leave it empty to use "
                + "the circuit\u{2019}s own name\(named)"
            : "Applies to this session only. Leave it empty to use the name recorded "
                + "by the logger\(named)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text(target.isTrack ? "Rename Track" : "Rename Session")
                .font(.token(theme.typography.headline))
            TextField(fallback.isEmpty ? SessionSummary.untitledText : fallback, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit(commit)
            Text(hint)
                .font(.token(theme.typography.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.spacing.lg)
        .onAppear { name = (target.isTrack ? currentTrackName : target.summary.customName) ?? "" }
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}
