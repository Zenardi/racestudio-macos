import Foundation

/// A typed failure bringing an attached video back (issue 9.6).
public enum VideoAttachmentError: Error, Equatable, Sendable {
    /// The file could not be bookmarked, or the bookmark no longer resolves —
    /// deleted, unreadable, or on a volume that is not mounted.
    case unresolvable
    /// The bookmark resolved, but the file moved since it was attached: it must
    /// be re-linked rather than silently played from wherever it landed.
    case stale
}

/// The session video persisted with a workspace (issue 9.6): a re-openable
/// reference to the footage plus the alignment the operator settled on.
///
/// The file itself is referenced by **bookmark**, not by path, so a `.rsproj`
/// reopened in a later launch can re-acquire a user-picked file under the App
/// Sandbox — the same mechanism the 2.3 recent-files list uses.
public struct VideoAttachment: Codable, Equatable, Sendable {

    /// The bookmark the file is re-acquired through.
    public let bookmark: Data

    /// The file's name, shown while the footage is attached (and when it can no
    /// longer be found).
    public let displayName: String

    /// The 9.5 sync offset in seconds, so a reopened workspace is aligned exactly
    /// as it was left. Always finite: a non-finite input is sanitized to `0`,
    /// which would otherwise defeat ``VideoSyncModel``'s clamp on the next load.
    public let offset: Double

    public init(bookmark: Data, displayName: String, offset: Double = 0) {
        self.bookmark = bookmark
        self.displayName = displayName
        self.offset = offset.isFinite ? offset : 0
    }

    /// The same footage re-aligned to `newOffset` — what a trim or a re-anchor
    /// persists.
    public func withOffset(_ newOffset: Double) -> VideoAttachment {
        VideoAttachment(bookmark: bookmark, displayName: displayName, offset: newOffset)
    }
}

/// Turns a user-picked video file into a persistable ``VideoAttachment`` and
/// back (issue 9.6).
///
/// The bookmark mechanism is injected through the 2.3 ``BookmarkStoring`` seam,
/// so tests exercise both failure paths without creating real security-scoped
/// bookmarks; production passes ``SecurityScopedBookmarkStore``.
public struct VideoAttachmentStore {

    private let bookmarks: BookmarkStoring

    public init(bookmarks: BookmarkStoring) {
        self.bookmarks = bookmarks
    }

    /// Attach the video at `url`, aligned by `offset` seconds.
    ///
    /// - Throws: ``VideoAttachmentError/unresolvable`` when the file cannot be
    ///   bookmarked — failing here rather than producing an attachment that could
    ///   never be resolved.
    public func attach(_ url: URL, offset: Double = 0) throws -> VideoAttachment {
        do {
            return VideoAttachment(bookmark: try bookmarks.data(for: url),
                                   displayName: url.lastPathComponent, offset: offset)
        } catch {
            throw VideoAttachmentError.unresolvable
        }
    }

    /// Re-acquire the file `attachment` refers to.
    ///
    /// - Throws: ``VideoAttachmentError/stale`` when the file moved (the panel
    ///   offers to re-link) and ``VideoAttachmentError/unresolvable`` when it is
    ///   gone. Neither aborts a project load — the workspace opens without
    ///   footage.
    public func resolve(_ attachment: VideoAttachment) throws -> URL {
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.url(for: attachment.bookmark)
        } catch {
            throw VideoAttachmentError.unresolvable
        }
        guard !resolved.isStale else { throw VideoAttachmentError.stale }
        return resolved.url
    }
}
