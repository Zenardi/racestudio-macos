import Foundation

/// Coordinates bringing files into the app (issue 2.3): it validates incoming
/// URLs from the open panel or drag-and-drop, then drives `SessionStore.load`
/// and records each in the recents list.
///
/// The SwiftUI shell only supplies the panel, the `.onDrop`, and the "Open
/// Recent" menu; all validation/coordination lives here so it is unit-tested.
public struct ImportCoordinator {

    private let store: SessionStore
    private let recents: RecentFilesStore

    public init(store: SessionStore, recents: RecentFilesStore) {
        self.store = store
        self.recents = recents
    }

    /// Filter `urls` to the supported telemetry types (`.xrk`/`.xrz`,
    /// case-insensitive), removing duplicates (by resolved path) while
    /// preserving first-seen order.
    public func accept(urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var accepted: [URL] = []
        for url in urls where SupportedFileType(url: url) != nil {
            if seen.insert(url.resolvingSymlinksInPath().path).inserted {
                accepted.append(url)
            }
        }
        return accepted
    }

    /// Accept `urls`, then import each: record it in recents (best-effort) and
    /// load it through the `SessionStore` exactly once.
    @MainActor
    public func importFiles(_ urls: [URL]) async {
        for url in accept(urls: urls) {
            try? recents.add(url)
            await store.load(url: url)
        }
    }
}
