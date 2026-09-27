import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// Wires the Core import + library stack for the shell (issues 2.3 + 8.14): a
/// `SessionStore`, a `RecentFilesStore` (UserDefaults + security-scoped
/// bookmarks), a `ManagedFileStore` holding RaceStudio's own copy of every
/// imported file, a `LibraryBrowserModel` (the RS3-style landing browser), and the
/// `ImportCoordinator` that the Open panel and drag-and-drop forward to.
///
/// Importing **adopts** the file — copies it into the app's Application Support
/// directory — then decodes that copy and indexes it. The library therefore never
/// depends on a file the user might move or delete, and (because the copy lives
/// inside the sandbox container) reopening it needs no security-scoped bookmark.
/// A completed import offers to open the session for analysis, suppressibly.
///
/// It holds no testable logic of its own — it only adapts AppKit/SwiftUI events
/// into Core calls (all validation/recents/library/adoption logic lives in
/// `RaceStudioCore`), so it stays out of the coverage metric.
@MainActor
final class AppModel: ObservableObject {

    /// The observable load state the analysis window (2.4/8.3) renders.
    let store: SessionStore

    /// The recents list backing the "Open Recent" menu.
    let recents: RecentFilesStore

    /// The session library browser — the app's landing window (issue 8.14).
    let library: LibraryBrowserModel

    /// The running build's version, shown on the Home footer and in About.
    let version = AppVersion.current

    private let coordinator: ImportCoordinator
    private let loader: SessionLoading
    private let libraryURL: URL
    /// RaceStudio's own copy of each imported telemetry file.
    private let files: ManagedFileStore
    /// Whether a finished import opens the session, asks, or stays put.
    private let followUpPolicy: ImportFollowUpPolicy

    init() {
        let loader = FFISessionLoader()
        let store = SessionStore(loader: loader)
        let recents = RecentFilesStore(
            bookmarks: SecurityScopedBookmarkStore(),
            store: UserDefaultsKeyValueStore())
        let libraryURL = LibraryStore.defaultURL()
        let files = ManagedFileStore(directory: ManagedFileStore.defaultDirectory())
        self.loader = loader
        self.store = store
        self.recents = recents
        self.libraryURL = libraryURL
        self.files = files
        self.followUpPolicy = ImportFollowUpPolicy(store: UserDefaultsKeyValueStore())
        self.library = LibraryBrowserModel(loadingFrom: libraryURL, loader: loader, files: files)
        self.coordinator = ImportCoordinator(store: store, recents: recents)
    }

    /// Present the standard Open panel and import the chosen telemetry file(s)
    /// (`.xrk` / `.xrz` / `.csv`) into the library.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedFileType.allContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importToLibrary(panel.urls)
    }

    /// Forward dropped item providers (file URLs) into the library.
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.importToLibrary([url]) }
            }
        }
        return handled
    }

    /// Re-open a recent entry for analysis via its security-scoped bookmark,
    /// bracketing the scoped access.
    func openRecent(_ url: URL) {
        guard let resolved = try? recents.resolve(url) else {
            objectWillChange.send() // a stale entry was pruned; refresh the menu
            return
        }
        Task {
            // As in `openFromLibrary`, access must outlive the asynchronous load.
            defer { recents.endAccess(resolved) }
            await store.load(url: resolved)
        }
    }

    /// Import `urls` into the library: adopt each into RaceStudio's own storage,
    /// decode the copy, index it, and persist. Then offer to open it (issue: a
    /// finished import used to give no signal that anything was ready to look at).
    func importToLibrary(_ urls: [URL]) {
        objectWillChange.send()
        Task {
            var failed: [URL] = []
            var imported: [SessionSummary] = []
            for url in coordinator.accept(urls: urls) {
                // Recents still tracks the *picked* file, so "Open Recent" keeps
                // naming what the user chose rather than an internal copy.
                try? recents.add(url)
                do {
                    // Adopt before decoding: the library must reference a file the
                    // app owns, so deleting the original never strands the session.
                    let owned = try files.adopt(url)
                    let loaded = try await loader.load(owned, onProgress: { _ in })
                    imported.append(library.add(loaded.session, sourceURL: owned))
                    // A save failure is non-fatal — the session is already in the
                    // in-memory library and re-imports next launch — so it stays
                    // best-effort, unlike a decode failure which is surfaced below.
                    try? library.save(to: libraryURL)
                } catch {
                    failed.append(url)
                }
            }
            if !failed.isEmpty { presentImportFailure(failed) }
            followUp(on: imported)
        }
    }

    /// Open a library session for full analysis; the shared store transitions the
    /// main window from the browser to the analysis view.
    ///
    /// RaceStudio's own copy lives inside the app's container, so it is read
    /// directly. A row imported before adoption existed still points at a
    /// user-picked file and is re-opened through its security-scoped bookmark: in
    /// the sandbox the plain `sourceURL` is unreadable in any later launch, because
    /// the Powerbox grant from the import does not survive the process.
    func openFromLibrary(_ summary: SessionSummary) {
        if files.isManaged(summary.sourceURL) {
            Task { await store.load(url: summary.sourceURL) }
            return
        }
        guard let resolved = try? recents.resolve(summary.sourceURL) else {
            presentUnreadable(summary.sourceURL)
            return
        }
        Task {
            // Access must outlive the load, so it is released here rather than
            // when this method returns.
            defer { recents.endAccess(resolved) }
            await store.load(url: resolved)
        }
    }

    // MARK: - After an import

    /// Act on the policy's decision for a finished import.
    private func followUp(on imported: [SessionSummary]) {
        switch followUpPolicy.followUp(for: imported) {
        case .stay:
            break
        case .open(let summary):
            openFromLibrary(summary)
        case .ask(let summary):
            askToOpen(summary)
        }
    }

    /// Offer to open a just-imported session, with a suppression checkbox that
    /// records the answer as a standing preference in either direction.
    private func askToOpen(_ summary: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Imported “\(summary.displayTitle)”"
        let laps = "\(summary.lapCount) lap\(summary.lapCount == 1 ? "" : "s")"
        alert.informativeText = "\(laps) recorded \(SessionDate.text(summary.date)).\n\n"
            + "Open it in Analysis now?"
        alert.addButton(withTitle: "Open in Analysis")
        alert.addButton(withTitle: "Stay in Library")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always do this, don’t ask again"
        let open = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            followUpPolicy.preference = open ? .always : .never
        }
        if open { openFromLibrary(summary) }
    }

    // MARK: - Failure reporting

    /// Report a library entry the app can no longer read — moved, deleted, or
    /// imported before its bookmark could be stored.
    private func presentUnreadable(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Can\u{2019}t open \u{201C}\(url.lastPathComponent)\u{201D}"
        alert.informativeText = "RaceStudio no longer has permission to read this file. "
            + "It may have been moved, renamed, or deleted.\n\nRe-import it with File \u{25B8} Open."
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Surface files that couldn't be imported rather than dropping them silently
    /// (an unsupported/corrupt `.xrk` otherwise vanishes with no feedback).
    /// Matches the Open-workspace failure alert in `WorkspaceBar`.
    private func presentImportFailure(_ urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Couldn’t import “\(urls[0].lastPathComponent)”"
            : "Couldn’t import \(urls.count) files"
        alert.informativeText = "The file couldn’t be read or decoded — it may be corrupt, "
            + "an unsupported format, or no longer available.\n\n\(names)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
