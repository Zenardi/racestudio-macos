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
/// ``ExportProgressModel``'s. The export runs off the main thread, so the
/// window keeps drawing while the sheet is up, and after **Hide** the window
/// can be used as usual.
struct ExportProgressSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var progress: ExportProgressModel
    @ObservedObject var coordinator: VideoExportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            if let failure = coordinator.failure {
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
        .onChange(of: progress.state) { announce($0) }
    }

    // MARK: - States

    private var running: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(L10n.format(.exportProgressTitle, coordinator.fileName))
                .font(.token(theme.typography.headline))
                .lineLimit(2)
            if coordinator.isPreparing || progress.progress == nil {
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
                Button(L10n.string(.exportControlHide)) { coordinator.dismiss() }
                Button(L10n.string(.exportControlCancel)) { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.state != .running)
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
                Button(L10n.string(.exportControlDone)) { coordinator.finish(progress: progress) }
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
                Button(L10n.string(.exportControlDone)) { coordinator.finish(progress: progress) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Say the end of the export to VoiceOver users, who may have hidden the sheet.
    private func announce(_ state: ExportProgressModel.State) {
        let message: String
        switch state {
        case .finished(let url): message = L10n.format(.exportProgressFinished, url.lastPathComponent)
        case .failed: message = progress.failureMessage()?.title ?? ""
        case .idle, .running, .cancelling: return
        }
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// The workspace bar's button for an export whose sheet is hidden (issue
/// 9.14): the percent while it runs — click to show the sheet again.
struct ExportStatusButton: View {
    @EnvironmentObject private var progress: ExportProgressModel
    @ObservedObject var coordinator: VideoExportCoordinator

    var body: some View {
        if coordinator.startedHere, progress.isActive, coordinator.route == nil {
            Button { coordinator.showProgress() } label: {
                Label(L10n.format(.exportProgressBadge, "\(Int(progress.fraction * 100))%"),
                      systemImage: "film.stack")
                    .monospacedDigit()
            }
            .help(progress.statusLine())
        }
    }
}
