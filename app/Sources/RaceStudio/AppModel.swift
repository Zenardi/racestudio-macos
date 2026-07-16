import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// Wires the Core import stack for the shell (issue 2.3): a `SessionStore`, a
/// `RecentFilesStore` (UserDefaults + security-scoped bookmarks), and the
/// `ImportCoordinator` that the Open panel, drag-and-drop, and "Open Recent"
/// menu forward to.
///
/// It holds no testable logic of its own — it only adapts AppKit/SwiftUI events
/// into Core calls (all validation/recents/bookmark logic lives in
/// `RaceStudioCore`), so it stays out of the coverage metric.
@MainActor
final class AppModel: ObservableObject {

    /// The observable load state the summary screen (2.4) will render.
    let store: SessionStore

    /// The recents list backing the "Open Recent" menu. `@Published`-adjacent:
    /// the menu re-reads `recents.entries` when `objectWillChange` fires.
    let recents: RecentFilesStore

    private let coordinator: ImportCoordinator

    init() {
        let store = SessionStore()
        let recents = RecentFilesStore(
            bookmarks: SecurityScopedBookmarkStore(),
            store: UserDefaultsKeyValueStore())
        self.store = store
        self.recents = recents
        self.coordinator = ImportCoordinator(store: store, recents: recents)
    }

    /// Present the standard Open panel and import the chosen `.xrk`/`.xrz` file.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xrk, .xrz]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    /// Forward dropped item providers (file URLs) to the coordinator.
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.importURLs([url]) }
            }
        }
        return handled
    }

    /// Re-open a recent entry via its security-scoped bookmark, bracketing the
    /// scoped access.
    func openRecent(_ url: URL) {
        guard let resolved = try? recents.resolve(url) else {
            objectWillChange.send() // a stale entry was pruned; refresh the menu
            return
        }
        defer { recents.endAccess(resolved) }
        importURLs([resolved])
    }

    private func importURLs(_ urls: [URL]) {
        objectWillChange.send()
        Task { await coordinator.importFiles(urls) }
    }
}
