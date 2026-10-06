import AVFoundation
import Foundation

/// Why an export's output settings cannot be encoded (issue 9.13).
public enum UnsupportedOutputReason: Equatable, Sendable {
    /// This Mac has no encoder for the codec.
    case codecUnavailable(ExportCodec)
    /// The output frame is larger than the codec can carry.
    case dimensionsTooLarge(width: Int, height: Int, codec: ExportCodec)
    /// The output frame is too small to encode.
    case dimensionsTooSmall(width: Int, height: Int)
}

/// Why an overlay export failed (issue 9.13). Every failure is one of these —
/// never a crash — and none leaves a file behind.
public enum OverlayExportError: Error, Equatable, Sendable {
    /// The footage cannot be opened or decoded.
    case sourceUnreadable
    /// The footage has no video (an audio-only file).
    case noVideoTrack
    /// The range holds no frame of the footage.
    case rangeOutsideFootage
    /// The output settings cannot be encoded.
    case unsupportedOutput(UnsupportedOutputReason)
    /// The destination's volume lacks room for the estimated file plus a 10%
    /// margin: `required` and `available` bytes.
    case insufficientDiskSpace(required: Int64, available: Int64)
    /// Encoding or writing the output failed; the message says why.
    case writerFailed(String)
    /// The export was cancelled.
    case cancelled
}

extension OverlayExportError {

    /// The typed error for whatever failed inside an export.
    ///
    /// - A typed error passes through; a cancelled task or AVFoundation
    ///   operation is ``cancelled``.
    /// - A full disk — AVFoundation's, Cocoa's or POSIX's, at any depth of
    ///   underlying errors — is ``insufficientDiskSpace(required:available:)``
    ///   naming `requiredBytes`.
    /// - Footage AVFoundation cannot parse or decode is ``sourceUnreadable``.
    /// - Anything else is ``writerFailed(_:)`` with the system's message.
    public init(mapping error: Error, requiredBytes: Int64) {
        if let typed = error as? OverlayExportError {
            self = typed
        } else if error is CancellationError {
            self = .cancelled
        } else if Self.isDiskFull(error as NSError) {
            self = .insufficientDiskSpace(required: requiredBytes, available: 0)
        } else {
            self = Self.mapping(error as NSError)
        }
    }

    /// The AVFoundation codes that mean the footage cannot be read.
    private static let unreadableCodes: Set<AVError.Code> = [
        .fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound, .decodeFailed,
        .undecodableMediaData, .contentIsProtected, .contentIsUnavailable, .operationNotSupportedForAsset,
        .noLongerPlayable
    ]

    private static func mapping(_ error: NSError) -> OverlayExportError {
        if error.domain == AVFoundationErrorDomain, let code = AVError.Code(rawValue: error.code) {
            if code == .operationCancelled { return .cancelled }
            if unreadableCodes.contains(code) { return .sourceUnreadable }
        }
        return .writerFailed(error.localizedDescription)
    }

    /// Whether `error`, or any error under it, reports a full disk or quota.
    private static func isDiskFull(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
             (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)), (NSPOSIXErrorDomain, Int(EDQUOT)):
            return true
        default:
            return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isDiskFull) ?? false
        }
    }
}
