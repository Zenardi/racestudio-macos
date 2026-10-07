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
    /// The video frames the plan exports (``ExportPlan/frameCount``).
    private let plannedFrames: Int
    private let queue = DispatchQueue(label: "com.racestudio.overlay-export", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let willFinish: @Sendable () async -> Void
    private let didStartFinishing: @Sendable () -> Void

    private struct State {
        var cancelled = false
        var finishing = false
        var frames = 0
        /// The run waiting for the file to be finished: resumed once, by the
        /// writer's completion or by a cancel, whichever comes first.
        var finished: CheckedContinuation<Void, Error>?
    }

    /// A pipeline encoding `composition` as `plan` says into a new file at `url`.
    /// - Parameters:
    ///   - willFinish: called once every sample is written, just before the
    ///     file is finished — a seam for the tests.
    ///   - didStartFinishing: called on the pipeline's queue once the writer
    ///     has been told to finish — a seam for the tests.
    /// - Throws: whatever AVFoundation throws creating the reader or writer.
    init(composition: OverlayComposition, plan: ExportPlan, writingTo url: URL,
         willFinish: @escaping @Sendable () async -> Void = {},
         didStartFinishing: @escaping @Sendable () -> Void = {}) async throws {
        self.willFinish = willFinish
        self.didStartFinishing = didStartFinishing
        plannedFrames = plan.frameCount
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

    /// Whether every sample is written and the file is being finished.
    var isFinishing: Bool { state.withLock { $0.finishing } }

    /// The writer's status — for the tests.
    var writerStatus: AVAssetWriter.Status { writer.status }

    /// Stop the export: the encode at its next frame, or — while the file is
    /// being finished — the run, at once. ``run()`` then throws
    /// ``OverlayExportError/cancelled``.
    ///
    /// A writer already told to finish is left to finish (issue 205). Cancelled
    /// that early in its finish, it could stay `.writing` for good and never
    /// call the finish's completion handler, which the run waited for. Its file
    /// is in the export's scratch directory, which the exporter removes.
    ///
    /// The cancel and the finish meet on the pipeline's queue, so a cancel
    /// either cancels the writer before it is told to finish, or ends a run
    /// already waiting for the finish — never one in between.
    func cancel() {
        if state.withLock({ $0.cancelled = true; return $0.finishing }) {
            queue.async { self.resumeFinished() }
        }
    }

    /// Encode everything, then finish the file.
    /// - Throws: ``OverlayExportError/cancelled`` after a cancel, or what the
    ///   reader or writer failed with.
    func run() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { done.resume(with: Result { try self.pumpAll() }) }
        }
        await willFinish()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { self.finish(then: done) }
        }
        if isCancelled { throw OverlayExportError.cancelled }
        guard writer.status == .completed else { throw writer.error ?? Self.unknownFailure }
    }

    // MARK: - Internals

    private static let unknownFailure = OverlayExportError.writerFailed("The video could not be written.")

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Finish the file, on the pipeline's queue — or, cancelled already,
    /// cancel the writer instead. A cancel arriving after this point is queued
    /// behind it (see ``cancel()``).
    private func finish(then done: CheckedContinuation<Void, Error>) {
        let cancelled = state.withLock { state -> Bool in
            state.finishing = true
            if !state.cancelled { state.finished = done }
            return state.cancelled
        }
        if cancelled {
            writer.cancelWriting()
            done.resume(throwing: OverlayExportError.cancelled)
            return
        }
        writer.finishWriting { self.resumeFinished() }
        didStartFinishing()
    }

    /// Resume the run waiting for the finish — once, whoever asks first.
    private func resumeFinished() {
        state.withLock { state -> CheckedContinuation<Void, Error>? in
            defer { state.finished = nil }
            return state.finished
        }?.resume()
    }

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
            try checkEveryFrameWasRead()
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    /// Fail a read that ended short of the plan (issue 204): AVFoundation drops
    /// a frame whose composition request was cancelled, or that a decoder could
    /// not produce, and still ends the read `.completed`. The plan promises its
    /// frame count within one frame, so one frame short passes.
    private func checkEveryFrameWasRead() throws {
        guard framesWritten + 1 >= plannedFrames else { throw OverlayExportError.sourceUnreadable }
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
