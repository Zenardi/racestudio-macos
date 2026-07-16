import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ImportCoordinator` (issue 2.3) — the logic that validates incoming
/// URLs (open panel / drag-and-drop), then drives `SessionStore.load` and the
/// recents list. Logic only; the SwiftUI panel/drop/menu glue lives in the shell.
@Suite struct ImportCoordinatorTests {

    private func makeRecents() -> RecentFilesStore {
        RecentFilesStore(bookmarks: FakeBookmarkStore(), store: InMemoryKeyValueStore())
    }

    @MainActor private func makeCoordinator(
        loader: SessionLoading = CountingSessionLoader(),
        recents: RecentFilesStore? = nil
    ) -> ImportCoordinator {
        ImportCoordinator(store: SessionStore(loader: loader), recents: recents ?? makeRecents())
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - accept(urls:)

    @MainActor @Test func test_accept_filters_non_xrk_urls() {
        let coordinator = makeCoordinator()

        let accepted = coordinator.accept(urls: [
            url("/data/a.xrk"), url("/data/notes.txt"),
            url("/data/b.xrz"), url("/data/sheet.csv")
        ])

        #expect(accepted.map(\.lastPathComponent) == ["a.xrk", "b.xrz"])
    }

    @MainActor @Test func test_accept_is_case_insensitive() {
        let coordinator = makeCoordinator()

        let accepted = coordinator.accept(urls: [url("/data/A.XRK"), url("/data/B.Xrz")])

        #expect(accepted.map(\.lastPathComponent) == ["A.XRK", "B.Xrz"])
    }

    @MainActor @Test func test_accept_dedupes_and_preserves_order() {
        let coordinator = makeCoordinator()

        let accepted = coordinator.accept(urls: [
            url("/data/a.xrk"), url("/data/b.xrz"), url("/data/a.xrk")
        ])

        #expect(accepted.map(\.lastPathComponent) == ["a.xrk", "b.xrz"])
    }

    // MARK: - importFiles(_:)

    @MainActor @Test func test_import_calls_session_store_once() async {
        let loader = CountingSessionLoader()
        let recents = makeRecents()
        let coordinator = makeCoordinator(loader: loader, recents: recents)

        await coordinator.importFiles([url("/data/a.xrk")])

        #expect(loader.callCount == 1)
        #expect(recents.entries.map(\.lastPathComponent) == ["a.xrk"])
    }

    @MainActor @Test func test_import_skips_unsupported_urls() async {
        let loader = CountingSessionLoader()
        let recents = makeRecents()
        let coordinator = makeCoordinator(loader: loader, recents: recents)

        await coordinator.importFiles([url("/data/notes.txt")])

        #expect(loader.callCount == 0)
        #expect(recents.entries.isEmpty)
    }
}
