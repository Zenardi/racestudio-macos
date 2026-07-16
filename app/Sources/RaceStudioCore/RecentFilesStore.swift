import Foundation

/// Key/value persistence for the recents list.
///
/// Injected into ``RecentFilesStore`` so unit tests use an in-memory store and
/// never touch the real user defaults; the shell supplies a `UserDefaults`-backed
/// implementation.
public protocol KeyValueStoring {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// The Recent Files list, persisted as security-scoped bookmarks so entries can
/// be re-opened across relaunches under the App Sandbox (issue 2.3).
///
/// The list is most-recent-first, de-duplicated by resolved path, and pruned to
/// ``maxCount`` (default 10). A stale or broken bookmark is removed from the list
/// and surfaced as a typed ``BookmarkError`` on ``resolve(_:)`` rather than
/// crashing; an empty list is a valid state. Bookmark encoding and persistence
/// are injected, so this logic is unit-tested without the real filesystem.
public final class RecentFilesStore {

    /// One persisted recent entry: the resolved path (for identity/dedupe and
    /// display) plus its bookmark blob (for re-resolution).
    private struct Entry: Codable, Equatable {
        let path: String
        let bookmark: Data
    }

    private let bookmarks: BookmarkStoring
    private let store: KeyValueStoring
    private let maxCount: Int
    private let key: String
    private var entriesList: [Entry]

    /// - Parameters:
    ///   - bookmarks: bookmark encoder/decoder (production: security-scoped).
    ///   - store: key/value persistence (production: `UserDefaults`).
    ///   - maxCount: maximum retained entries (default 10).
    ///   - key: persistence key.
    public init(
        bookmarks: BookmarkStoring,
        store: KeyValueStoring,
        maxCount: Int = 10,
        key: String = "com.racestudio.recentFiles.v1"
    ) {
        self.bookmarks = bookmarks
        self.store = store
        self.maxCount = maxCount
        self.key = key
        self.entriesList = Self.decode(store.data(forKey: key))
    }

    /// The recent files, most-recent-first, as file URLs (for display and as
    /// handles for ``resolve(_:)``).
    public var entries: [URL] {
        entriesList.map { URL(fileURLWithPath: $0.path) }
    }

    /// Record `url` as the most-recent file: a fresh bookmark is created, any
    /// existing entry for the same resolved path is removed, and the list is
    /// pruned to ``maxCount``.
    public func add(_ url: URL) throws {
        let bookmark = try bookmarks.data(for: url)
        let path = url.resolvingSymlinksInPath().path
        entriesList.removeAll { $0.path == path }
        entriesList.insert(Entry(path: path, bookmark: bookmark), at: 0)
        if entriesList.count > maxCount {
            entriesList = Array(entriesList.prefix(maxCount))
        }
        persist()
    }

    /// Resolve a recent entry to a usable file URL, beginning security-scoped
    /// access (balance it with ``endAccess(_:)``).
    ///
    /// A stale or unresolvable bookmark is removed from the list and reported as
    /// a typed ``BookmarkError`` instead of crashing.
    public func resolve(_ url: URL) throws -> URL {
        let path = url.resolvingSymlinksInPath().path
        guard let index = entriesList.firstIndex(where: { $0.path == path }) else {
            throw BookmarkError.unresolvable
        }
        let resolved: URL
        let isStale: Bool
        do {
            (resolved, isStale) = try bookmarks.url(for: entriesList[index].bookmark)
        } catch {
            entriesList.remove(at: index)
            persist()
            throw BookmarkError.unresolvable
        }
        if isStale {
            entriesList.remove(at: index)
            persist()
            throw BookmarkError.stale
        }
        _ = resolved.startAccessingSecurityScopedResource()
        return resolved
    }

    /// End security-scoped access to a URL returned by ``resolve(_:)``.
    public func endAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Remove the entry for `url` (by resolved path), if present.
    public func remove(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        entriesList.removeAll { $0.path == path }
        persist()
    }

    /// Empty the recents list.
    public func clear() {
        entriesList.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        store.set(try? JSONEncoder().encode(entriesList), forKey: key)
    }

    private static func decode(_ data: Data?) -> [Entry] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
