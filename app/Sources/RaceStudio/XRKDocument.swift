import SwiftUI
import UniformTypeIdentifiers
import RaceStudioCore

/// SwiftUI document adapter for an opened `.xrk`/`.xrz` telemetry file.
///
/// A thin `ReferenceFileDocument` conformance: it reads the opened file's raw
/// bytes into memory through `RaceStudioCore.DocumentContents` — which validates
/// the input and rejects empty/unreadable files with a typed `DocumentError` —
/// **without decoding them** (decoding is issue 2.2). All logic lives in
/// `RaceStudioCore`; this type only bridges SwiftUI's document lifecycle, so the
/// shell stays out of the coverage metric.
///
/// The app opens files read-only (see `RaceStudio.entitlements`), so `snapshot`
/// / `fileWrapper` exist only to satisfy the protocol and simply echo the loaded
/// bytes back — RaceStudio never rewrites a telemetry file.
final class XRKDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.xrk, .xrz] }

    let contents: DocumentContents

    init(configuration: ReadConfiguration) throws {
        contents = try DocumentContents(fileContents: configuration.file.regularFileContents)
    }

    func snapshot(contentType: UTType) throws -> Data {
        contents.bytes
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
