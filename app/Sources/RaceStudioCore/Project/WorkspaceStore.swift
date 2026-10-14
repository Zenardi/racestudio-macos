import CryptoKit
import Foundation
import os

/// Each session's workspace, kept in the app's own folder (issue 9.20): one
/// `.rsproj` per session, named by its content id
/// (``SessionIndex/contentID(for:)``), so the same session opened from any
/// path — the library, *Open…*, *Open Recent* — finds the workspace it was left
/// with. Saving and reading are the 5.4 ``ProjectStore``'s, so the format, its
/// migrations and its atomic write are the same as a workspace file's.
///
/// A saved workspace that can't be read — corrupt, or from a newer RaceStudio —
/// is moved aside rather than left to be saved over, so nothing the operator
/// made is ever destroyed by opening the session.
public final class WorkspaceStore {

    /// What ``load(session:)`` found.
    public enum Loaded: Equatable, Sendable {
        /// The session has no saved workspace.
        case none
        /// The saved workspace, migrated and validated.
        case document(ProjectDocument)
        /// The saved workspace couldn't be read. `keptAside` says whether it
        /// was moved out of the way; when it wasn't, it must not be saved over.
        case unreadable(keptAside: Bool)
    }

    /// The folder workspaces are kept in.
    public let directory: URL
    private let projects: ProjectStore
    private let fileManager: FileManager
    private static let logger = Logger(subsystem: "com.racestudio.core", category: "workspace")

    /// - Parameters:
    ///   - directory: where the workspaces are kept; created on the first save.
    ///   - validator: re-validates each math channel on load (production: the
    ///     FFI parser).
    ///   - write: the write primitive, injected so a failed write is testable;
    ///     an atomic `Data.write` by default.
    ///   - fileManager: moves and deletes the files.
    public init(directory: URL, validator: ExpressionValidating, write: ((Data, URL) throws -> Void)? = nil,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.projects = ProjectStore(validator: validator, write: write)
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/RaceStudio/Workspaces` — beside
    /// `library.json` and the session copies.
    public static func defaultDirectory() -> URL {
        LibraryStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    // MARK: - Files

    /// The workspace file of the session with `contentID`.
    public func url(forSession contentID: String) -> URL {
        directory.appendingPathComponent("\(Self.fileName(for: contentID)).\(ProjectStore.fileExtension)")
    }

    /// Where an unreadable workspace of the session with `contentID` is kept.
    public func asideURL(forSession contentID: String) -> URL {
        directory.appendingPathComponent("\(Self.fileName(for: contentID)).unreadable.\(ProjectStore.fileExtension)")
    }

    /// The file name for `contentID`: the id itself when it is a content id (64
    /// lowercase hex digits), otherwise its SHA-256 — so a name can never leave
    /// the folder, and two ids never share a file even on a case-insensitive
    /// disk.
    private static func fileName(for contentID: String) -> String {
        let isContentID = contentID.utf8.count == 64
            && contentID.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        guard !isContentID else { return contentID }
        return SHA256.hash(data: Data(contentID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading and writing

    /// The saved workspace of the session with `contentID`. One that can't be
    /// read is moved aside (replacing an older one kept aside), so the next
    /// save can never overwrite it.
    public func load(session contentID: String) -> Loaded {
        let url = url(forSession: contentID)
        guard fileManager.fileExists(atPath: url.path) else { return .none }
        do {
            return .document(try projects.load(from: url))
        } catch {
            Self.logger.error("unreadable workspace: \(String(describing: error), privacy: .public)")
            return .unreadable(keptAside: keepAside(url, at: asideURL(forSession: contentID)))
        }
    }

    /// Save `document` as the workspace of the session with `contentID`,
    /// atomically. Throws ``ProjectError/ioFailure`` when it can't be written;
    /// the previous workspace, if any, is left intact.
    public func save(_ document: ProjectDocument, session contentID: String) throws {
        try projects.save(document, to: url(forSession: contentID))
    }

    /// Delete the workspace of the session with `contentID`, if there is one.
    public func delete(session contentID: String) {
        let url = url(forSession: contentID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("could not delete a workspace: \(String(describing: error), privacy: .public)")
        }
    }

    /// Move `url` to `aside`, replacing an older file kept there; whether it
    /// moved.
    private func keepAside(_ url: URL, at aside: URL) -> Bool {
        do {
            if fileManager.fileExists(atPath: aside.path) { try fileManager.removeItem(at: aside) }
            try fileManager.moveItem(at: url, to: aside)
            return true
        } catch {
            Self.logger.error("could not keep a workspace aside: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
