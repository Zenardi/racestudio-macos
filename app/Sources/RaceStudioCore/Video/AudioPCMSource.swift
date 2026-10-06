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

    public init(url: URL) {
        self.url = url
    }

    /// Whether the file at `url` has an audio track to sync from — `false` for a
    /// video-only clip, or a file that is not readable media.
    public static func hasAudioTrack(at url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    public func monoPCM(targetRate: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> MonoPCM {
        let asset = AVURLAsset(url: url)
        let track = try await audioTrack(of: asset)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        try Task.checkCancellation()
        let reader = try Self.reader(for: asset, track: track)
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard let output = reader.outputs.first as? AVAssetReaderTrackOutput else {
            throw AudioSyncFailure.unreadableAudio
        }
        var decoding = Decoding(targetRate: targetRate, duration: duration)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let fraction = decoding.append(buffer) { progress(fraction) }
        }
        guard reader.status == .completed, let pcm = decoding.finish() else {
            throw AudioSyncFailure.unreadableAudio
        }
        return pcm
    }

    /// The asset's first audio track, or a typed failure.
    private func audioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioSyncFailure.unreadableAudio
        }
        guard let track = tracks.first else { throw AudioSyncFailure.noAudioTrack }
        return track
    }

    /// A started reader decoding `track` to interleaved native-endian float32.
    private static func reader(for asset: AVURLAsset, track: AVAssetTrack) throws -> AVAssetReader {
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
        return reader
    }
}

/// The running state of one decode: the decimator (built from the first
/// chunk's format), the output so far, and where the audio starts.
private struct Decoding {
    let targetRate: Int
    let duration: Double
    var decimator: PCMDecimator?
    var samples: [Float] = []
    var startTime: Double?
    var scratch: [Float] = []

    init(targetRate: Int, duration: Double) {
        self.targetRate = targetRate
        self.duration = duration
    }

    /// Downmix and decimate one decoded chunk; returns the progress fraction,
    /// or `nil` for a chunk with no usable audio.
    mutating func append(_ buffer: CMSampleBuffer) -> Double? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        if decimator == nil {
            decimator = PCMDecimator(sourceRate: Int(description.mSampleRate),
                                     channels: Int(description.mChannelsPerFrame), targetRate: targetRate)
            if let decimator { samples.reserveCapacity(Int(duration * Double(decimator.outputRate)) + 1) }
        }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if startTime == nil { startTime = start.isFinite ? start : 0 }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        scratch = [Float](repeating: 0, count: count)
        let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: base)
        }
        guard status == kCMBlockBufferNoErr, decimator != nil else { return nil }
        scratch.withUnsafeBufferPointer { samples += decimator?.process($0) ?? [] }
        let end = start + CMSampleBufferGetDuration(buffer).seconds
        return duration > 0 && end.isFinite ? min(1, max(0, end / duration)) : nil
    }

    /// The decoded clip, or `nil` when no chunk carried audio.
    mutating func finish() -> MonoPCM? {
        guard var decimator else { return nil }
        samples += decimator.finish()
        return MonoPCM(samples: samples, sampleRate: decimator.outputRate, startTime: startTime ?? 0)
    }
}
