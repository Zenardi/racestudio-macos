import Foundation

/// A typed failure resolving a persisted recent-file bookmark (issue 2.3).
public enum BookmarkError: Error, Equatable {
    /// The bookmark resolved, but the file moved/changed and the bookmark is
    /// stale — it must be recreated (or dropped from recents).
    case stale
    /// The bookmark could not be resolved to a URL at all (deleted, corrupt).
    case unresolvable
}

/// Encodes/decodes a file URL as a persistable bookmark.
///
/// Injected into ``RecentFilesStore`` so unit tests substitute a fake and never
/// create real security-scoped bookmarks; production is
/// ``SecurityScopedBookmarkStore``.
public protocol BookmarkStoring {
    /// Create bookmark data for `url`.
    func data(for url: URL) throws -> Data
    /// Resolve bookmark `data` back into a URL, reporting whether it is stale.
    func url(for data: Data) throws -> (url: URL, isStale: Bool)
}

/// Production `BookmarkStoring` using **security-scoped** bookmarks, so a
/// user-picked file can be re-opened from Recents across launches under the App
/// Sandbox (the `com.apple.security.files.bookmarks.app-scope` entitlement
/// declared in 2.1).
public struct SecurityScopedBookmarkStore: BookmarkStoring {

    public init() {}

    public func data(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func url(for data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
