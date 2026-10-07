import AVFoundation
import Foundation
import os

/// The encode of one overlay export (issue 9.13): an `AVAssetReader` pulls the
/// composition's frames through the ``OverlayCompositor`` (and its decoded
/// sound), and an `AVAssetWriter` encodes them into an MP4 at the plan's codec
/// and bit rate.
///
/// The pull loop runs on its own serial queue, never on a cooperative thread:
/// it blocks on each composed frame. It serves whichever writer input is
/// ready — the writer's readiness flags interleave the tracks — and naps a
/// millisecond when neither is, so memory stays bounded by the writer's own
/// queues however long the footage. A ``cancel()`` is seen within one frame.
final class ExportPipeline: @unchecked Sendable {

    /// One reader output feeding one writer input.
    private struct Lane {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let countsFrames: Bool
    }

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let lanes: [Lane]
    private let queue = DispatchQueue(label: "com.racestudio.overlay-export", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, frames: 0))

    /// A pipeline encoding `composition` as `plan` says into a new file at `url`.
    /// - Throws: whatever AVFoundation throws creating the reader or writer.
    init(composition: OverlayComposition, plan: ExportPlan, writingTo url: URL) async throws {
        reader = try AVAssetReader(asset: composition.asset)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let timescale = ExportEncoding.timescale(for: plan.footage.frameRate)
        writer.movieTimeScale = timescale
        let frames = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await composition.asset.loadTracks(withMediaType: .video),
            videoSettings: OverlayCompositor.bgraAttributes)
        frames.videoComposition = composition.videoComposition
        frames.alwaysCopiesSampleData = false
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: ExportEncoding.video(for: plan))
        video.mediaTimeScale = timescale
        var lanes = [Lane(output: frames, input: video, countsFrames: true)]
        if let track = try await composition.asset.loadTracks(withMediaType: .audio).first,
           let audio = plan.footage.audio {
            let sound = AVAssetReaderTrackOutput(track: track, outputSettings: ExportEncoding.pcm(for: audio))
            sound.alwaysCopiesSampleData = false
            lanes.append(Lane(output: sound,
                              input: AVAssetWriterInput(mediaType: .audio, outputSettings: ExportEncoding.audio(
                                for: audio, bitRate: plan.audioBitRate)),
                              countsFrames: false))
        }
        for lane in lanes {
            lane.input.expectsMediaDataInRealTime = false
            guard reader.canAdd(lane.output), writer.canAdd(lane.input) else {
                throw OverlayExportError.writerFailed("The export's \(lane.input.mediaType.rawValue) track "
                                                      + "cannot be encoded.")
            }
            reader.add(lane.output)
            writer.add(lane.input)
        }
        self.lanes = lanes
    }

    /// Video frames written so far.
    var framesWritten: Int { state.withLock { $0.frames } }

    /// Stop the encode at the next frame; ``run()`` then throws
    /// ``OverlayExportError/cancelled``.
    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// Encode everything, then finish the file.
    /// - Throws: ``OverlayExportError/cancelled`` after a cancel, or what the
    ///   reader or writer failed with.
    func run() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { done.resume(with: Result { try self.pumpAll() }) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Self.unknownFailure }
    }

    // MARK: - Internals

    private static let unknownFailure = OverlayExportError.writerFailed("The video could not be written.")

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Pull every sample through, or stop both ends and rethrow.
    private func pumpAll() throws {
        do {
            guard reader.startReading() else { throw reader.error ?? Self.unknownFailure }
            guard writer.startWriting() else { throw writer.error ?? Self.unknownFailure }
            writer.startSession(atSourceTime: .zero)
            var finished = Array(repeating: false, count: lanes.count)
            while finished.contains(false) {
                if isCancelled { throw OverlayExportError.cancelled }
                var moved = false
                for index in lanes.indices where !finished[index] && lanes[index].input.isReadyForMoreMediaData {
                    finished[index] = try pumpOne(lanes[index])
                    moved = true
                }
                if writer.status == .failed { throw writer.error ?? Self.unknownFailure }
                if !moved { usleep(1_000) }
            }
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// Move one sample along `lane`; `true` once the lane has run dry.
    private func pumpOne(_ lane: Lane) throws -> Bool {
        guard let sample = lane.output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw reader.error ?? Self.unknownFailure }
            lane.input.markAsFinished()
            return true
        }
        guard lane.input.append(sample) else { throw writer.error ?? Self.unknownFailure }
        if lane.countsFrames { state.withLock { $0.frames += 1 } }
        return false
    }
}
