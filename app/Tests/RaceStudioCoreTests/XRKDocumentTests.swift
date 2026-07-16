import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `DocumentContents` — the byte-reading core that the shell's
/// `XRKDocument` (`ReferenceFileDocument`) delegates to (issue 2.1).
///
/// The document reads an opened `.xrk`/`.xrz` file's bytes into memory **without
/// decoding** (decoding is 2.2) and rejects empty/unreadable input with a typed
/// `DocumentError`. `ReferenceFileDocument.ReadConfiguration` cannot be
/// constructed in a unit test, so the validation logic lives in `RaceStudioCore`
/// and is tested here directly.
@Suite struct XRKDocumentTests {

    /// Given a non-empty file, the bytes are stored verbatim — no parsing, no
    /// transformation. This is the "load, don't decode" contract of 2.1.
    @Test func test_document_reads_bytes_without_decoding() throws {
        let raw = Data("<h not-really-decoded header bytes\u{00}\u{01}\u{02}".utf8)

        let contents = try DocumentContents(fileContents: raw)

        #expect(contents.bytes == raw)
    }

    /// An empty file is a distinct, typed failure — not a silent empty buffer or
    /// a crash.
    @Test func test_empty_document_throws_typed_error() {
        #expect(throws: DocumentError.empty) {
            _ = try DocumentContents(fileContents: Data())
        }
    }

    /// A file whose contents could not be read (no regular-file data) surfaces as
    /// `DocumentError.unreadable` rather than crashing on a force-unwrap.
    @Test func test_unreadable_document_throws_typed_error() {
        #expect(throws: DocumentError.unreadable) {
            _ = try DocumentContents(fileContents: nil)
        }
    }
}
