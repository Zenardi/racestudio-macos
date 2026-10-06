import AVFoundation
import Foundation

/// A video's audio decoded to mono PCM (issue 9.8) — what the engine-pitch
/// estimator reads.
public struct MonoPCM: Equatable, Sendable {
    /// The mono samples.
    public let samples: [Float]
    /// Samples per second.
    public let sampleRate: Int
    /// The video time (seconds) of `samples[0]` — an estimate made against the
    /// samples is moved onto the video's clock by it.
    public let startTime: Double

    /// A clip of `samples` at `sampleRate` Hz whose first sample sits at video
    /// time `startTime`.
    public init(samples: [Float], sampleRate: Int, startTime: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }
}

/// Where the audio an auto-sync run matches comes from (issue 9.8). Production
/// reads the footage with ``AVAssetAudioPCMSource``; tests substitute a fake.
public protocol AudioPCMSource: Sendable {
    /// Decode the audio as mono at (no less than) `targetRate` Hz, reporting
    /// progress in `0...1` as it goes.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled
    ///   (checked between chunks); ``AudioSyncFailure/noAudioTrack`` or
    ///   ``AudioSyncFailure/unreadableAudio`` when there is nothing to decode.
    func monoPCM(targetRate: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> MonoPCM
}

/// The production ``AudioPCMSource``: `AVAssetReader` decodes the footage's
/// first audio track to interleaved 32-bit float PCM, and a ``PCMDecimator``
/// downmixes and decimates each chunk as it arrives — so a ten-minute 48 kHz
/// clip is never held at its source rate, only one chunk plus the ~8 kHz mono
/// output (about 2 MB a minute).
public struct AVAssetAudioPCMSource: AudioPCMSource {

    /// The footage to read.
    public let url: URL

    /// A source reading the footage at `url` (opened on each read).
    public init(url: URL) {
        self.url = url
    }

    /// Whether the file at `url` has an audio track to sync from — `false` for a
    /// video-only clip, or a file that is not readable media.
    public static func hasAudioTrack(at url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Decode, reporting progress in whole percents, each once — at most a
    /// hundred updates however many chunks the decoder delivers. The read
    /// blocks a cooperative thread chunk by chunk; cancelling also cancels the
    /// reader, so a slow read stops at the reader's next chance rather than
    /// only between chunks.
    public func monoPCM(targetRate: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> MonoPCM {
        let asset = AVURLAsset(url: url)
        let track = try await audioTrack(of: asset)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        // An indefinite or absurd duration only drives progress and a capacity
        // hint, never a trap.
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0
        try Task.checkCancellation()
        let (reader, output) = try Self.reader(for: asset, track: track)
        defer { if reader.status == .reading { reader.cancelReading() } }
        var decoding = Decoding(targetRate: targetRate, duration: duration)
        var reported = -1
        let cancel = ReaderCancellation(reader: reader)
        try await withTaskCancellationHandler {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try autoreleasepool { try decoding.append(buffer) }
                if let percent = decoding.percent, percent > reported {
                    reported = percent
                    progress(Double(percent) / 100)
                }
            }
        } onCancel: {
            cancel.fire()
        }
        try Task.checkCancellation()
        guard reader.status == .completed, let pcm = decoding.finish() else {
            throw AudioSyncFailure.unreadableAudio
        }
        return pcm
    }

    /// The asset's first audio track, or a typed failure. A cancellation stays
    /// a cancellation.
    private func audioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AudioSyncFailure.unreadableAudio
        }
        guard let track = tracks.first else { throw AudioSyncFailure.noAudioTrack }
        return track
    }

    /// A started reader decoding `track` to interleaved native-endian float32,
    /// with the output it reads from.
    private static func reader(for asset: AVURLAsset,
                               track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        guard let reader = try? AVAssetReader(asset: asset) else { throw AudioSyncFailure.unreadableAudio }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioSyncFailure.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw AudioSyncFailure.unreadableAudio }
        return (reader, output)
    }
}

/// Cancels a reader from the task's cancellation handler, which runs on
/// whichever thread cancels; the reader then hands out no more samples
/// (`copyNextSampleBuffer()` returns `nil`).
private struct ReaderCancellation: @unchecked Sendable {
    let reader: AVAssetReader

    func fire() {
        reader.cancelReading()
    }
}

/// The running state of one decode: the decimator (built from the first
/// chunk's format), the output so far, where the audio starts, and how far
/// through the clip the last chunk ended.
private struct Decoding {
    /// The most output samples reserved up front (about half an hour at
    /// 8.8 kHz); a longer clip grows its buffer as it goes.
    static let reservationCap: Double = 16_000_000

    let targetRate: Int
    let duration: Double
    var decimator: PCMDecimator?
    var samples: [Float] = []
    var startTime: Double?
    /// Whole percent of the clip decoded so far, when the duration is known.
    var percent: Int?
    private var scratch: [Float] = []

    init(targetRate: Int, duration: Double) {
        self.targetRate = targetRate
        self.duration = duration
    }

    /// Downmix and decimate one decoded chunk. A chunk without audio data is
    /// skipped; one whose data cannot be copied is a failure — dropping it
    /// would silently shorten the clip and skew the offset.
    mutating func append(_ buffer: CMSampleBuffer) throws {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        if decimator == nil {
            // A corrupt rate (NaN, ∞, absurd) reads as no audio, never a trap.
            let rate = description.mSampleRate
            let sourceRate = rate.isFinite && rate >= 1 && rate <= Double(PCMDecimator.maxSourceRate)
                ? Int(rate.rounded()) : 0
            decimator = PCMDecimator(sourceRate: sourceRate, channels: Int(description.mChannelsPerFrame),
                                     targetRate: targetRate)
            if let decimator {
                let expected = min(duration * Double(decimator.outputRate), Self.reservationCap)
                samples.reserveCapacity(Int(expected) + 1)
            }
        }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        if scratch.count != count { scratch = [Float](repeating: 0, count: count) }
        let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferNoErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { throw AudioSyncFailure.unreadableAudio }
        guard decimator != nil else { return }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if startTime == nil { startTime = start.isFinite ? start : 0 }
        scratch.withUnsafeBufferPointer { samples += decimator?.process($0) ?? [] }
        let end = start + CMSampleBufferGetDuration(buffer).seconds
        if duration > 0, end.isFinite {
            percent = Int((min(1, max(0, end / duration)) * 100).rounded(.down))
        }
    }

    /// The decoded clip, or `nil` when no chunk carried audio.
    mutating func finish() -> MonoPCM? {
        guard var decimator else { return nil }
        samples += decimator.finish()
        return MonoPCM(samples: samples, sampleRate: decimator.outputRate, startTime: startTime ?? 0)
    }
}
