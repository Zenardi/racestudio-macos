import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// Wires the Core import + library stack for the shell (issues 2.3 + 8.14): a
/// `SessionStore`, a `RecentFilesStore` (UserDefaults + security-scoped
/// bookmarks), a `LibraryBrowserModel` (the RS3-style landing browser), and the
/// `ImportCoordinator` that the Open panel and drag-and-drop forward to.
///
/// Importing a file decodes it, adds it to the persisted library (dedup by
/// content id), and refreshes the browser — without opening it for analysis, so
/// the browser stays visible. Opening a library session loads it into the shared
/// store, which switches the main window to the analysis view.
///
/// It holds no testable logic of its own — it only adapts AppKit/SwiftUI events
/// into Core calls (all validation/recents/library logic lives in
/// `RaceStudioCore`), so it stays out of the coverage metric.
@MainActor
final class AppModel: ObservableObject {

    /// The observable load state the analysis window (2.4/8.3) renders.
    let store: SessionStore

    /// The recents list backing the "Open Recent" menu.
    let recents: RecentFilesStore

    /// The session library browser — the app's landing window (issue 8.14).
    let library: LibraryBrowserModel

    private let coordinator: ImportCoordinator
    private let loader: SessionLoading
    private let libraryURL: URL

    init() {
        let loader = FFISessionLoader()
        let store = SessionStore(loader: loader)
        let recents = RecentFilesStore(
            bookmarks: SecurityScopedBookmarkStore(),
            store: UserDefaultsKeyValueStore())
        let libraryURL = LibraryStore.defaultURL()
        self.loader = loader
        self.store = store
        self.recents = recents
        self.libraryURL = libraryURL
        self.library = LibraryBrowserModel(loadingFrom: libraryURL, loader: loader)
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

    /// Import `urls` into the library: decode each, add it (dedup by content id),
    /// and persist — without opening it, so the browser list simply updates.
    func importToLibrary(_ urls: [URL]) {
        objectWillChange.send()
        Task {
            var failed: [URL] = []
            for url in coordinator.accept(urls: urls) {
                try? recents.add(url)
                do {
                    let loaded = try await loader.load(url, onProgress: { _ in })
                    library.add(loaded.session, sourceURL: url)
                    // A save failure is non-fatal — the session is already in the
                    // in-memory library and re-imports next launch — so it stays
                    // best-effort, unlike a decode failure which is surfaced below.
                    try? library.save(to: libraryURL)
                } catch {
                    failed.append(url)
                }
            }
            if !failed.isEmpty { presentImportFailure(failed) }
        }
    }

    /// Open a library session for full analysis; the shared store transitions the
    /// main window from the browser to the analysis view.
    ///
    /// The URL is re-opened through its security-scoped bookmark. In the sandbox
    /// the plain `sourceURL` is unreadable in any later launch — the Powerbox
    /// grant from the import does not survive the process — so loading it
    /// directly failed for every session the user had imported earlier. The file
    /// still *stat*s (`isAvailable` stays true), which is why the row looked
    /// openable and simply did nothing.
    func openFromLibrary(_ summary: SessionSummary) {
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

    /// Surface files that couldn't be decoded during import rather than dropping
    /// them silently (an unsupported/corrupt `.xrk` otherwise vanishes with no
    /// feedback). Matches the Open-workspace failure alert in `WorkspaceBar`.
    private func presentImportFailure(_ urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Couldn’t import “\(urls[0].lastPathComponent)”"
            : "Couldn’t import \(urls.count) files"
        alert.informativeText = "The file couldn’t be decoded — it may be corrupt or "
            + "an unsupported format.\n\n\(names)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
