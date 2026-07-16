import Foundation
import UniformTypeIdentifiers

/// The AiM telemetry file types RaceStudio can open.
///
/// This is the testable classification logic the document-based shell (issue
/// 2.1) and the later open/drag/recents flows (2.3) build on. It lives in
/// `RaceStudioCore` — the 95%-coverage target — so extension handling is pinned
/// by unit tests rather than buried in a SwiftUI view.
///
/// Recognition is by file extension only and is **case-insensitive**: Finder,
/// drag-and-drop, and recents can each hand us a differently-cased extension for
/// the same file.
public enum SupportedFileType: String, CaseIterable, Equatable {

    /// Uncompressed AiM telemetry container (`.xrk`).
    case xrk

    /// Compressed AiM telemetry container (`.xrz`).
    case xrz

    /// Classifies a bare path extension, case-insensitively.
    ///
    /// - Parameter pathExtension: An extension **without** the leading dot
    ///   (e.g. `"xrk"`, `"XRK"`). The empty string and any unsupported
    ///   extension yield `nil`.
    public init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }

    /// Classifies a file URL by its path extension, case-insensitively.
    ///
    /// - Parameter url: A file URL such as `file:///data/foo.XRK`. URLs without
    ///   a supported extension yield `nil`.
    public init?(url: URL) {
        self.init(pathExtension: url.pathExtension)
    }
}

public extension UTType {

    /// Uncompressed AiM telemetry (`.xrk`).
    ///
    /// Imported from AiM's declaration — RaceStudio reads these files but does
    /// not own the format. The identifier is kept in lock-step with the
    /// `UTImportedTypeDeclarations` entry in `Sources/RaceStudio/Info.plist` so
    /// Finder routes a `.xrk` to the app.
    static var xrk: UTType {
        UTType(importedAs: "com.aim-sportline.xrk")
    }

    /// Compressed AiM telemetry (`.xrz`). See ``xrk`` for the declaration
    /// contract.
    static var xrz: UTType {
        UTType(importedAs: "com.aim-sportline.xrz")
    }
}
