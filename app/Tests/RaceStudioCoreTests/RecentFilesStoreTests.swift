import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `RecentFilesStore` + `Bookmarks` (issue 2.3) — the recents list and
/// its security-scoped bookmark lifecycle.
///
/// The behaviour is exercised with an injected `FakeBookmarkStore` +
/// in-memory `KeyValueStore` so unit tests never touch the real user defaults or
/// create real bookmarks; one integration test covers the production
/// `SecurityScopedBookmarkStore` against a temp file.
@Suite struct RecentFilesStoreTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private func resolvedPath(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

    private func makeStore(
        bookmarks: FakeBookmarkStore = FakeBookmarkStore(),
        store: InMemoryKeyValueStore = InMemoryKeyValueStore()
    ) -> RecentFilesStore {
        RecentFilesStore(bookmarks: bookmarks, store: store)
    }

    // MARK: - Persistence + resolution

    @Test func test_recents_persist_and_resolve_via_bookmark() throws {
        let file = url("/data/session.xrk")
        let kv = InMemoryKeyValueStore()
        try makeStore(store: kv).add(file)

        // A fresh store from the same persisted defaults (as if relaunched).
        let reloaded = makeStore(store: kv)
        let resolved = try reloaded.resolve(file)

        #expect(resolvedPath(resolved) == resolvedPath(file))
        reloaded.endAccess(resolved)
    }

    @Test func test_recents_are_most_recent_first() throws {
        let store = makeStore()
        try store.add(url("/data/a.xrk"))
        try store.add(url("/data/b.xrk"))
        try store.add(url("/data/c.xrk"))

        #expect(store.entries.map(\.lastPathComponent) == ["c.xrk", "b.xrk", "a.xrk"])
    }

    @Test func test_recents_dedupe_by_path() throws {
        let store = makeStore()
        try store.add(url("/data/a.xrk"))
        try store.add(url("/data/b.xrk"))
        try store.add(url("/data/a.xrk"))

        #expect(store.entries.map(\.lastPathComponent) == ["a.xrk", "b.xrk"])
    }

    @Test func test_recents_pruned_to_max_ten() throws {
        let store = makeStore()
        for index in 1...12 {
            try store.add(url("/data/f\(index).xrk"))
        }

        #expect(store.entries.count == 10)
        #expect(store.entries.first?.lastPathComponent == "f12.xrk")
        #expect(store.entries.last?.lastPathComponent == "f3.xrk")
        #expect(!store.entries.map(\.lastPathComponent).contains("f1.xrk"))
    }

    // MARK: - Error paths

    @Test func test_stale_bookmark_is_removed_and_reported() throws {
        let file = url("/data/stale.xrk")
        let bookmarks = FakeBookmarkStore()
        bookmarks.stalePaths = [resolvedPath(file)]
        let store = makeStore(bookmarks: bookmarks)
        try store.add(file)

        #expect(throws: BookmarkError.stale) { try store.resolve(file) }
        #expect(store.entries.isEmpty)
    }

    @Test func test_broken_bookmark_is_removed_and_reported() throws {
        let file = url("/data/broken.xrk")
        let bookmarks = FakeBookmarkStore()
        bookmarks.brokenPaths = [resolvedPath(file)]
        let store = makeStore(bookmarks: bookmarks)
        try store.add(file)

        #expect(throws: BookmarkError.unresolvable) { try store.resolve(file) }
        #expect(store.entries.isEmpty)
    }

    @Test func test_resolve_unknown_url_throws_unresolvable() {
        let store = makeStore()

        #expect(throws: BookmarkError.unresolvable) { try store.resolve(url("/data/never-added.xrk")) }
    }

    // MARK: - Mutation

    @Test func test_remove_deletes_entry() throws {
        let store = makeStore()
        try store.add(url("/data/a.xrk"))
        try store.add(url("/data/b.xrk"))

        store.remove(url("/data/a.xrk"))

        #expect(store.entries.map(\.lastPathComponent) == ["b.xrk"])
    }

    @Test func test_clear_empties_recents() throws {
        let store = makeStore()
        try store.add(url("/data/a.xrk"))
        try store.add(url("/data/b.xrk"))

        store.clear()

        #expect(store.entries.isEmpty)
    }

    // MARK: - Empty / corrupt state

    @Test func test_empty_recents_is_valid() {
        let store = makeStore()

        #expect(store.entries.isEmpty)
    }

    @Test func test_corrupt_persistence_is_ignored() {
        let kv = InMemoryKeyValueStore(seed: ["k": Data("{ not valid json".utf8)])

        let store = RecentFilesStore(bookmarks: FakeBookmarkStore(), store: kv, key: "k")

        #expect(store.entries.isEmpty)
    }

    // MARK: - Production bookmark store (integration; no fixture needed)

    @Test func test_security_scoped_bookmark_round_trips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs_bookmark_\(UUID().uuidString).xrk")
        try Data("<h stub".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let subject = SecurityScopedBookmarkStore()
        let data = try subject.data(for: tmp)
        let (resolved, isStale) = try subject.url(for: data)

        #expect(!data.isEmpty)
        #expect(!isStale)
        #expect(resolved.resolvingSymlinksInPath().path == tmp.resolvingSymlinksInPath().path)
        #expect(resolved.startAccessingSecurityScopedResource())
        resolved.stopAccessingSecurityScopedResource()
    }
}
