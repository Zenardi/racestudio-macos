import CryptoKit
import Foundation

/// RaceStudio's own copy of each imported telemetry file.
///
/// The library used to reference the file the user picked, which made every row a
/// hostage to that file: moving, renaming, or deleting it left an entry that listed
/// but could not open, and under the App Sandbox the Powerbox grant did not survive
/// a relaunch either. Importing now **adopts** the file — copies it into the app's
/// Application Support directory, inside the sandbox container, so no entitlement
/// is required — and the library points at that copy for the session's lifetime.
///
/// Adoption is keyed by a hash of the file's **contents**, so re-importing the same
/// session (under any name) reuses the existing copy instead of accumulating
/// duplicates. ``discard(_:)`` is refused for any path outside ``directory``, so a
/// row that still points at a user-picked file can never have that file deleted.
public struct ManagedFileStore {

    /// A typed failure from adopting or discarding a file.
    public enum StorageError: Error, Equatable {
        /// The file to adopt could not be read.
        case unreadable
        /// The copy could not be written into the managed directory.
        case copyFailed
        /// The path is not inside the managed directory, so this store does not own
        /// it and will not delete it.
        case notManaged
    }

    /// Hex characters of the content digest kept in a managed filename. 16 hex
    /// characters is 64 bits — collision-free at any plausible library size, while
    /// leaving the original name readable in the Finder.
    private static let digestLength = 16

    /// Longest managed filename, in UTF-8 bytes (the HFS+/APFS limit).
    private static let maxNameBytes = 255

    private let directory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - directory: where copies are kept; created on first adoption.
    ///   - fileManager: injected so tests drive a scratch tree.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/RaceStudio/Sessions` — beside `library.json`,
    /// so the index and the files it references live and move together.
    public static func defaultDirectory() -> URL {
        LibraryStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Copy `url` into the managed directory and return the copy's location. The
    /// original is left untouched. Idempotent by content: adopting the same bytes
    /// again returns the existing copy without rewriting it.
    ///
    /// - Throws: ``StorageError/unreadable`` if `url` cannot be read,
    ///   ``StorageError/copyFailed`` if the copy cannot be committed.
    public func adopt(_ url: URL) throws -> URL {
        guard let data = fileManager.contents(atPath: url.path) else {
            throw StorageError.unreadable
        }
        let digest = Self.digest(of: data)
        let destination = directory.appendingPathComponent(Self.managedName(
            basename: url.deletingPathExtension().lastPathComponent,
            extension: url.pathExtension,
            digest: digest))
        // Same content, same name: the copy already on disk is the copy we want.
        if fileManager.fileExists(atPath: destination.path) { return destination }
        // Same content under a *different* name — the user re-downloaded and renamed
        // the session. Reuse the copy already adopted rather than writing a second
        // one: the library row dedups by decoded content id and would reference only
        // the newest, orphaning the other file with nothing left pointing at it.
        if let existing = existingCopy(digest: digest, extension: url.pathExtension) {
            return existing
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw StorageError.copyFailed
        }
        return destination
    }

    /// Whether `url` is a copy this store owns — and therefore whether deleting the
    /// library row may delete the file.
    public func isManaged(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    /// Delete the managed copy at `url`. A copy that is already gone is the caller's
    /// desired end state, so that succeeds.
    ///
    /// - Throws: ``StorageError/notManaged`` when `url` lies outside the managed
    ///   directory — the guard that keeps a user's own file safe.
    public func discard(_ url: URL) throws {
        guard isManaged(url) else { throw StorageError.notManaged }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw StorageError.copyFailed
        }
    }

    /// The managed filename for a file: `"<basename>-<digest>.<extension>"`.
    ///
    /// `basename` is sanitised to a single path component — a name containing `/` or
    /// `..` must not be able to place the copy outside the managed directory — and
    /// truncated so the whole name fits the filesystem limit. The digest and
    /// extension are never truncated, since they carry the identity and decide how
    /// the file is decoded.
    public static func managedName(basename: String, extension ext: String, digest: String) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let stem = "-\(digest)\(suffix)"
        var safe = basename.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        safe = safe.replacingOccurrences(of: "..", with: "-")
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { safe = "session" }
        // Trim the readable stem — never the digest — until the name fits.
        while safe.utf8.count + stem.utf8.count > maxNameBytes, !safe.isEmpty {
            safe.removeLast()
        }
        if safe.isEmpty { safe = "session" }
        return safe + stem
    }

    /// An already-adopted copy of this content, whatever name it was adopted under.
    /// Matched on the `-<digest>` marker every managed name carries.
    private func existingCopy(digest: String, extension ext: String) -> URL? {
        let suffix = ext.isEmpty ? "-\(digest)" : "-\(digest).\(ext)"
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        // Sorted so the answer stays deterministic if two copies somehow coexist.
        guard let match = names.filter({ $0.hasSuffix(suffix) }).sorted().first else { return nil }
        return directory.appendingPathComponent(match)
    }

    /// The leading ``digestLength`` hex characters of the SHA-256 of `data`.
    private static func digest(of data: Data) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(digestLength))
    }
}
