#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Puts a session downloaded from the MyChron into the library (issue #179).
@MainActor
public protocol DownloadedSessionImporting: AnyObject {
    /// Import the `.xrk` bytes downloaded for `session`, all or nothing: either
    /// the session is decoded, stored and listed, or nothing is kept and the
    /// error is thrown.
    func importDownloaded(_ data: Data, for session: DeviceSession) async throws
}

/// The library import for downloaded sessions: the same steps the Open panel
/// takes (adopt a copy, decode it, index it, persist the index), but starting
/// from bytes rather than a user-picked file.
///
/// The bytes are written to a scratch file and **decoded first**; only a
/// session that decodes is adopted into ``ManagedFileStore`` and added to the
/// library, so a download the decoder rejects leaves nothing behind. The
/// scratch file is always removed.
@MainActor
public final class DownloadedSessionImporter: DownloadedSessionImporting {

    private let files: ManagedFileStore
    private let loader: SessionLoading
    private let library: LibraryBrowserModel
    private let libraryURL: URL
    private let scratchDirectory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - files: RaceStudio's own copy store.
    ///   - loader: decodes the downloaded session.
    ///   - library: the library the session is added to.
    ///   - libraryURL: where the library index is saved after each import.
    ///   - scratchDirectory: where the bytes are staged before decoding.
    public init(files: ManagedFileStore, loader: SessionLoading, library: LibraryBrowserModel,
                libraryURL: URL, scratchDirectory: URL = FileManager.default.temporaryDirectory,
                fileManager: FileManager = .default) {
        self.files = files
        self.loader = loader
        self.library = library
        self.libraryURL = libraryURL
        self.scratchDirectory = scratchDirectory
        self.fileManager = fileManager
    }

    public func importDownloaded(_ data: Data, for session: DeviceSession) async throws {
        let staging = scratchDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(DeviceSessionText.libraryFileName(session))
        try data.write(to: staged)

        let loaded = try await loader.load(staged, onProgress: { _ in })
        let owned = try files.adopt(staged)
        library.add(loaded.session, sourceURL: owned, track: loaded.dataSource?.detectTrack())
        // As for the Open panel, a failed save is not fatal: the session is in
        // the in-memory library and the index is rewritten on the next import.
        try? library.save(to: libraryURL)
    }
}
#endif
