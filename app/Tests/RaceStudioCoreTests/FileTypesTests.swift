import Testing
import Foundation
import UniformTypeIdentifiers
@testable import RaceStudioCore

/// Tests for the file-type logic that the document-based shell (issue 2.1) and
/// the later open/import flows (2.3) depend on.
///
/// `SupportedFileType` and the `UTType.xrk`/`UTType.xrz` declarations live in
/// `RaceStudioCore` — the 95%-coverage logic target — so this behaviour is
/// unit-tested independently of the SwiftUI shell.
@Suite struct FileTypesTests {

    // MARK: - SupportedFileType(pathExtension:)

    /// Given the canonical lowercase `xrk` extension, the type resolves to `.xrk`.
    @Test func test_supported_type_for_xrk_extension() {
        #expect(SupportedFileType(pathExtension: "xrk") == .xrk)
    }

    /// Extension matching is case-insensitive: Finder and drag-and-drop hand us
    /// whatever case the file was saved with.
    @Test func test_supported_type_is_case_insensitive() {
        #expect(SupportedFileType(pathExtension: "XRK") == .xrk)
        #expect(SupportedFileType(pathExtension: "Xrk") == .xrk)
    }

    /// The compressed `.xrz` container is recognised too, also case-insensitively.
    @Test func test_xrz_extension_recognized() {
        #expect(SupportedFileType(pathExtension: "xrz") == .xrz)
        #expect(SupportedFileType(pathExtension: "XRZ") == .xrz)
    }

    /// Anything that is not an AiM telemetry extension — including the empty
    /// string — yields `nil` rather than a bogus type.
    @Test func test_unsupported_extension_returns_nil() {
        #expect(SupportedFileType(pathExtension: "csv") == nil)
        #expect(SupportedFileType(pathExtension: "txt") == nil)
        #expect(SupportedFileType(pathExtension: "") == nil)
    }

    // MARK: - SupportedFileType(url:)

    /// A file URL is classified by its path extension, case-insensitively, and
    /// unsupported URLs return `nil`.
    @Test func test_supported_type_from_url() {
        #expect(SupportedFileType(url: URL(fileURLWithPath: "/data/foo.XRK")) == .xrk)
        #expect(SupportedFileType(url: URL(fileURLWithPath: "/data/foo.xrk")) == .xrk)
        #expect(SupportedFileType(url: URL(fileURLWithPath: "/data/foo.xrz")) == .xrz)
        #expect(SupportedFileType(url: URL(fileURLWithPath: "/data/foo.txt")) == nil)
    }

    // MARK: - UTType declarations

    /// The `UTType.xrk`/`.xrz` static types resolve to the reverse-DNS
    /// identifiers declared in the app's `Info.plist`
    /// (`UTImportedTypeDeclarations`). Keeping the identifier in code and in the
    /// plist in lock-step is what lets Finder route a `.xrk` to the app.
    @Test func test_uttype_identifiers_match_declaration() {
        #expect(UTType.xrk.identifier == "com.aim-sportline.xrk")
        #expect(UTType.xrz.identifier == "com.aim-sportline.xrz")
    }
}
