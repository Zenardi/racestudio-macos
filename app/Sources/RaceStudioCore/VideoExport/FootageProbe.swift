import AVFoundation
import Foundation

/// Reads a ``FootageInfo`` from a footage file with AVFoundation (issue 9.13):
/// the first video track's nominal frame rate, stored size, rotation and
/// length, its codec, and the first audio track's format.
public enum FootageProbe {

    /// Describe the footage at `url`.
    ///
    /// - Throws: ``OverlayExportError/sourceUnreadable`` when the file is
    ///   missing or not readable media, ``OverlayExportError/noVideoTrack`` for
    ///   an audio-only file, ``OverlayExportError/cancelled`` when the calling
    ///   task is cancelled.
    public static func probe(_ url: URL) async throws -> FootageInfo {
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isReadable) else { throw OverlayExportError.sourceUnreadable }
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw OverlayExportError.noVideoTrack
            }
            let (rate, size, transform, range, formats) = try await video.load(
                .nominalFrameRate, .naturalSize, .preferredTransform, .timeRange, .formatDescriptions)
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioFormats = try await audio?.load(.formatDescriptions) ?? []
            try Task.checkCancellation()
            return FootageInfo(duration: range.duration.seconds, frameRate: FrameGrid(nominalFrameRate: Double(rate)),
                               naturalSize: size, rotation: FootageRotation(transform: transform),
                               audio: audio.map { _ in footageAudio(audioFormats.first) },
                               codec: fourCharacterCode(formats.first.map(CMFormatDescriptionGetMediaSubType)))
        } catch let error as OverlayExportError {
            throw error
        } catch is CancellationError {
            throw OverlayExportError.cancelled
        } catch {
            throw OverlayExportError.sourceUnreadable
        }
    }

    // MARK: - Internals

    /// The sample rate and channel count of an audio format (an unreadable
    /// format reads as 48 kHz stereo — the encoder's own default).
    private static func footageAudio(_ format: CMFormatDescription?) -> FootageAudio {
        guard let format, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else {
            return FootageAudio(sampleRate: 48_000, channels: 2)
        }
        return FootageAudio(sampleRate: stream.mSampleRate, channels: Int(stream.mChannelsPerFrame))
    }

    /// A codec's four-character code as text (`avc1`), or `""` without one.
    private static func fourCharacterCode(_ code: FourCharCode?) -> String {
        guard let code else { return "" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
