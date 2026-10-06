import AVFoundation
import Foundation
import Testing
@testable import RaceStudioCore

/// Whatever fails inside an overlay export — AVFoundation, the file system, a
/// cancelled task — reaches the caller as one typed ``OverlayExportError``
/// (issue 9.13), so the export sheet can always say what went wrong and how to
/// fix it.
@Suite struct OverlayExportErrorMappingTests {

    private func avError(_ code: AVError.Code, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "AV failure \(code.rawValue)"]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: info)
    }

    /// A typed error is passed through unchanged.
    @Test func test_a_typed_error_passes_through() {
        let typed = OverlayExportError.insufficientDiskSpace(required: 9, available: 1)

        #expect(OverlayExportError(mapping: typed, requiredBytes: 100) == typed)
    }

    /// A cancelled task, or a cancelled AVFoundation operation, is a cancel.
    @Test func test_cancellation_maps_to_cancelled() {
        #expect(OverlayExportError(mapping: CancellationError(), requiredBytes: 0) == .cancelled)
        #expect(OverlayExportError(mapping: avError(.operationCancelled), requiredBytes: 0) == .cancelled)
    }

    /// A full disk — however it is reported — is a disk-space failure naming
    /// the space the export needed.
    @Test func test_a_full_disk_maps_to_insufficient_disk_space() {
        let reports: [Error] = [
            avError(.diskFull),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT)),
            avError(.unknown, underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        ]

        for report in reports {
            #expect(OverlayExportError(mapping: report, requiredBytes: 4_096)
                    == .insufficientDiskSpace(required: 4_096, available: 0), "\(report)")
        }
    }

    /// Footage AVFoundation cannot parse or decode is unreadable.
    @Test(arguments: [AVError.Code.fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound,
                      .decodeFailed, .undecodableMediaData, .contentIsProtected, .contentIsUnavailable,
                      .operationNotSupportedForAsset, .noLongerPlayable])
    func test_undecodable_footage_maps_to_source_unreadable(_ code: AVError.Code) {
        #expect(OverlayExportError(mapping: avError(code), requiredBytes: 0) == .sourceUnreadable)
    }

    /// Any other failure is a writer failure that keeps the system's message.
    @Test func test_other_failures_map_to_writer_failed_with_the_message() {
        let encoder = avError(.encoderNotFound)
        let other = NSError(domain: "Elsewhere", code: 7, userInfo: [NSLocalizedDescriptionKey: "it broke"])

        #expect(OverlayExportError(mapping: encoder, requiredBytes: 0) == .writerFailed("AV failure -11834"))
        #expect(OverlayExportError(mapping: other, requiredBytes: 0) == .writerFailed("it broke"))
    }
}
