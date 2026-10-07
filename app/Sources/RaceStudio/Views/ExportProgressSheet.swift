import SwiftUI
import AppKit
import RaceStudioCore

/// The export's progress sheet (issue 9.14): while it runs, the percent, the
/// frames, the time elapsed and the time left, with **Cancel** and **Hide**
/// (the export carries on; the workspace bar brings the sheet back); then
/// **Reveal in Finder** and **Open**, or the failure in plain language with
/// its fix.
///
/// Thin: the states, the progress line and every message are
/// ``ExportProgressModel``'s, and what this window shows is its
/// ``ExportFlowModel``'s. The export runs off the main thread, so the window
/// keeps drawing while the sheet is up, and after **Hide** it can be used as
/// usual. Esc hides the sheet; it never cancels an export.
struct ExportProgressSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var progress: ExportProgressModel
    @ObservedObject var flow: ExportFlowModel
    /// Stops an export still being prepared.
    let cancelPreparation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            if let failure = flow.failure {
                failed(failure)
            } else {
                switch progress.state {
                case .idle, .running, .cancelling: running
                case .finished(let url): finished(url)
                case .failed: failed(progress.failureMessage() ?? ExportProgressModel.userMessage(for: .cancelled))
                }
            }
        }
        .padding(theme.spacing.lg)
        .frame(width: 460)
    }

    // MARK: - States

    private var running: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(L10n.format(.exportProgressTitle, flow.fileName))
                .font(.token(theme.typography.headline))
                .lineLimit(2)
            if flow.isPreparing || progress.progress == nil {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: progress.fraction)
                    .accessibilityValue(progress.statusLine())
            }
            Text(progress.state == .cancelling ? L10n.string(.exportProgressCancelling) : progress.statusLine())
                .font(.token(theme.typography.callout))
                .monospacedDigit()
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
            HStack {
                Spacer()
                Button(L10n.string(.exportControlCancel), action: cancel)
                    .disabled(!(flow.isPreparing || progress.state == .running))
                Button(L10n.string(.exportControlHide), action: flow.dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Label(L10n.format(.exportProgressFinished, url.lastPathComponent), systemImage: "checkmark.circle.fill")
                .font(.token(theme.typography.headline))
                .foregroundStyle(theme.palette.textPrimary.color(scheme))
                .lineLimit(2)
            HStack {
                Button(L10n.string(.exportControlReveal)) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button(L10n.string(.exportControlOpen)) { NSWorkspace.shared.open(url) }
                Spacer()
                Button(L10n.string(.exportControlDone)) { flow.finish(progress: progress) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: ExportUserMessage) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Label(message.title, systemImage: "exclamationmark.triangle.fill")
                .font(.token(theme.typography.headline))
                .foregroundStyle(theme.palette.negative.color(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(message.fix)
                .font(.token(theme.typography.body))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.string(.exportControlDone)) { flow.finish(progress: progress) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Cancel the export — or, before its first frame, its preparation.
    private func cancel() {
        if flow.isPreparing { cancelPreparation() } else { progress.cancel() }
    }
}

/// The workspace bar's button for this window's export while its sheet is
/// hidden (issue 9.14): the percent — click to show the sheet again.
struct ExportStatusButton: View {
    @EnvironmentObject private var progress: ExportProgressModel
    @ObservedObject var flow: ExportFlowModel

    var body: some View {
        if flow.showsBadge(progress: progress) {
            Button { flow.showProgress() } label: {
                Label(L10n.format(.exportProgressBadge, "\(Int(progress.fraction * 100))%"),
                      systemImage: "film.stack")
                    .monospacedDigit()
            }
            .help(progress.statusLine())
        }
    }
}
