import Foundation
@testable import RaceStudioCore

/// In-memory `KeyValueStoring` so recents-persistence tests never touch the real
/// user defaults or filesystem.
final class InMemoryKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    /// Seed a raw value (used to exercise the corrupt-data path).
    init(seed: [String: Data] = [:]) { storage = seed }

    func data(forKey key: String) -> Data? { storage[key] }

    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
    }
}

/// A `BookmarkStoring` that encodes a URL's resolved path as its "bookmark",
/// with knobs to simulate stale or broken bookmarks — so recents tests never
/// create real security-scoped bookmarks.
final class FakeBookmarkStore: BookmarkStoring, @unchecked Sendable {
    /// Resolved paths whose bookmark should report `isStale == true`.
    var stalePaths: Set<String> = []
    /// Resolved paths whose bookmark should fail to resolve.
    var brokenPaths: Set<String> = []

    func data(for url: URL) throws -> Data {
        Data(url.resolvingSymlinksInPath().path.utf8)
    }

    func url(for data: Data) throws -> (url: URL, isStale: Bool) {
        let path = String(bytes: data, encoding: .utf8) ?? ""
        if brokenPaths.contains(path) { throw BookmarkError.unresolvable }
        return (URL(fileURLWithPath: path), stalePaths.contains(path))
    }
}

/// A `SessionLoading` that counts invocations (and records URLs) without any
/// real decode — used to assert `SessionStore.load` is driven exactly once.
final class CountingSessionLoader: SessionLoading, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var loadedURLs: [URL] = []

    func load(_ url: URL) async throws -> Session {
        callCount += 1
        loadedURLs.append(url)
        return Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }
}
