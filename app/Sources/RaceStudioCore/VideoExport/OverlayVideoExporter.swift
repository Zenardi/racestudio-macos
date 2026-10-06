import Foundation
import os

/// Exports footage as an MP4 with the telemetry overlay burned in (issue 9.13).
///
/// ```swift
/// let plan = try ExportPlan.make(request: request, footage: footage, timeline: laps,
///                                encoders: .system).get()
/// for try await progress in exporter.export(plan, overlay: overlay, to: url) {
///     sheet.show(progress)                      // several times a second
/// }                                             // done: the file is at `url`
/// ```
///
/// - **Checks first:** the destination's volume must hold the plan's estimate
///   plus 10% (``DiskSpaceChecking``), or the export fails before writing.
/// - **Encodes** through an ``ExportPipeline``: the reader pulls each frame
///   through the ``OverlayCompositor``; the writer encodes at the plan's codec
///   and bit rate, hardware first. ADR 0008 records why a reader and writer,
///   not `AVAssetExportSession`.
/// - **Never leaves a partial file:** it writes into a scratch directory on
///   the destination's volume and moves the finished file into place in one
///   step — replacing any file already there only then. The scratch directory
///   is removed however the export ends.
/// - **Cancellable:** ``cancel()`` — or cancelling the task reading the
///   stream — stops it within a frame; the stream then throws
///   ``OverlayExportError/cancelled`` once its files are gone.
public actor OverlayVideoExporter {

    /// A fresh directory for an export's temporary file, on the same volume
    /// as `destination` so the finished file moves into place atomically.
    public static let itemReplacementDirectory: @Sendable (URL) throws -> URL = { destination in
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination.deletingLastPathComponent(), create: true)
    }

    private let diskSpace: any DiskSpaceChecking
    private let progressInterval: Duration
    private let scratchDirectory: @Sendable (URL) throws -> URL
    private var jobs: [UUID: ExportJob] = [:]

    /// - Parameters:
    ///   - diskSpace: where free space is checked.
    ///   - progressInterval: how often progress is emitted.
    ///   - scratchDirectory: makes the directory an export writes into; the
    ///     exporter removes it when the export ends.
    public init(diskSpace: any DiskSpaceChecking = VolumeDiskSpace(),
                progressInterval: Duration = .milliseconds(250),
                scratchDirectory: @escaping @Sendable (URL) throws -> URL
                    = OverlayVideoExporter.itemReplacementDirectory) {
        self.diskSpace = diskSpace
        self.progressInterval = progressInterval
        self.scratchDirectory = scratchDirectory
    }

    /// Export `plan` with `overlay` burned in, to `destination`.
    ///
    /// - Returns: the export's progress, every ``progressInterval`` and once
    ///   more, complete, when the file is in place. The stream throws an
    ///   ``OverlayExportError`` when the export fails or is cancelled.
    public nonisolated func export(_ plan: ExportPlan, overlay: ExportOverlay,
                                   to destination: URL) -> AsyncThrowingStream<ExportProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(plan, overlay: overlay, to: destination, reporting: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cancel every export in progress.
    public func cancel() {
        for job in jobs.values { job.cancel() }
    }

    // MARK: - Internals

    private func run(_ plan: ExportPlan, overlay: ExportOverlay, to destination: URL,
                     reporting continuation: AsyncThrowingStream<ExportProgress, Error>.Continuation) async {
        let job = ExportJob(totalFrames: plan.frameCount)
        let id = UUID()
        jobs[id] = job
        let ticker = Task { [progressInterval] in
            while (try? await Task.sleep(for: progressInterval)) != nil { continuation.yield(job.progress) }
        }
        do {
            try await withTaskCancellationHandler {
                try await perform(plan, overlay: overlay, to: destination, job: job)
            } onCancel: {
                job.cancel()
            }
            ticker.cancel()
            await ticker.value
            continuation.yield(job.completed)
            continuation.finish()
        } catch {
            ticker.cancel()
            await ticker.value
            continuation.finish(throwing: OverlayExportError(mapping: error, requiredBytes: plan.requiredBytes))
        }
        jobs[id] = nil
    }

    private func perform(_ plan: ExportPlan, overlay: ExportOverlay, to destination: URL,
                         job: ExportJob) async throws {
        try job.checkCancelled()
        if let available = try diskSpace.availableCapacity(for: destination.deletingLastPathComponent()),
           available < plan.requiredBytes {
            throw OverlayExportError.insufficientDiskSpace(required: plan.requiredBytes, available: available)
        }
        let scratch = try scratchDirectory(destination)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("\(UUID().uuidString).mp4")
        let composition: OverlayComposition
        do {
            composition = try await OverlayComposition.make(plan: plan, overlay: overlay)
        } catch {
            throw Self.readFailure(error)
        }
        try job.checkCancelled()
        let pipeline = try await ExportPipeline(composition: composition, plan: plan, writingTo: file)
        job.attach(pipeline)
        try await pipeline.run()
        try job.checkCancelled()
        try Self.place(file, at: destination)
    }

    /// A failure reading the footage: a typed error or a cancel stays one;
    /// anything else means the footage is unreadable.
    private static func readFailure(_ error: Error) -> Error {
        if error is OverlayExportError || error is CancellationError { return error }
        return OverlayExportError.sourceUnreadable
    }

    /// Move the finished `file` to `destination` in one step, replacing
    /// whatever is there.
    private static func place(_ file: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
    }
}

/// One export in progress: its cancel flag, its pipeline once it has one, and
/// its clock.
final class ExportJob: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, pipeline: ExportPipeline?.none))
    private let totalFrames: Int
    private let started = ContinuousClock.now

    init(totalFrames: Int) {
        self.totalFrames = totalFrames
    }

    /// Cancel the export: its pipeline now, or as soon as it has one.
    func cancel() {
        state.withLock { $0.cancelled = true; return $0.pipeline }?.cancel()
    }

    /// Hand the job its pipeline, cancelled at once if the job already is.
    func attach(_ pipeline: ExportPipeline) {
        if state.withLock({ $0.pipeline = pipeline; return $0.cancelled }) { pipeline.cancel() }
    }

    /// - Throws: ``OverlayExportError/cancelled`` once the job is cancelled.
    func checkCancelled() throws {
        if state.withLock({ $0.cancelled }) { throw OverlayExportError.cancelled }
    }

    /// The progress so far.
    var progress: ExportProgress {
        ExportProgress(framesDone: state.withLock { $0.pipeline }?.framesWritten ?? 0, totalFrames: totalFrames,
                       elapsed: elapsed)
    }

    /// The progress of the finished export: every frame done.
    var completed: ExportProgress {
        ExportProgress(framesDone: totalFrames, totalFrames: totalFrames, elapsed: elapsed)
    }

    private var elapsed: TimeInterval {
        let components = (ContinuousClock.now - started).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
