import Foundation

/// A typed failure reading an opened telemetry document.
///
/// The shell surfaces these instead of crashing on a bad file, so the open flow
/// (issue 2.3) can present a real error to the user.
public enum DocumentError: Error, Equatable {

    /// The file was read successfully but contained no bytes.
    case empty

    /// The file's regular-file contents could not be obtained.
    case unreadable
}

/// The in-memory bytes of an opened `.xrk`/`.xrz` document — **loaded, not
/// decoded**.
///
/// This is the core of the shell's `XRKDocument` (`ReferenceFileDocument`,
/// issue 2.1): it validates the raw file contents and holds them verbatim.
/// Parsing the container is issue 2.2, so nothing here interprets the bytes.
///
/// `ReferenceFileDocument.ReadConfiguration` cannot be constructed in a unit
/// test, so this validation lives in `RaceStudioCore` (the coverage target) and
/// the shell's document type is a thin adapter over it.
public struct DocumentContents: Equatable {

    /// The opened file's raw bytes, stored exactly as read.
    public let bytes: Data

    /// Validates and stores an opened file's contents without decoding them.
    ///
    /// - Parameter fileContents: The regular-file contents from the document's
    ///   read configuration, or `nil` when they could not be read.
    /// - Throws: ``DocumentError/unreadable`` when `fileContents` is `nil`, or
    ///   ``DocumentError/empty`` when it is present but empty.
    public init(fileContents: Data?) throws {
        guard let data = fileContents else {
            throw DocumentError.unreadable
        }
        guard !data.isEmpty else {
            throw DocumentError.empty
        }
        self.bytes = data
    }
}
