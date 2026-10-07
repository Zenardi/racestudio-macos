import AppKit
import RaceStudioCore

/// The app's delegate (issue 9.14): it owns the one overlay export that can
/// run at a time — so the export outlives any view that shows it — and asks
/// before quitting while it runs.
///
/// Thin by design: the export's states and messages are
/// ``ExportProgressModel``'s, in `RaceStudioCore`; this only asks the question
/// and waits for the cancel to clean up before letting the app quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The app's overlay export, shown by the window that started it.
    let videoExport = ExportProgressModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard videoExport.isActive else { return .terminateNow }
        guard ExportGuardAlert.confirmCancel(message: L10n.string(.exportQuitMessage),
                                             confirm: L10n.string(.exportQuitConfirm)) else {
            return .terminateCancel
        }
        Task { @MainActor in
            await videoExport.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The question asked before quitting, closing the window or closing the
/// session while an export runs (issue 9.14). *Keep Exporting* is the default
/// button; cancelling is the destructive choice.
enum ExportGuardAlert {

    /// Ask; `true` when the operator chose to cancel the export.
    @MainActor
    static func confirmCancel(message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string(.exportQuitTitle)
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string(.exportQuitKeep))
        let cancel = alert.addButton(withTitle: confirm)
        cancel.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
