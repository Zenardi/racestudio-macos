import AVFoundation
import CoreGraphics
import Foundation
@testable import RaceStudioCore

/// An exported movie read back (issue 9.13): its timing, size, codec and
/// sound, every video frame's time, and the frames asked for decoded.
struct MovieReadback {
    let duration: Double
    let frameRate: Float
    let size: CGSize
    let codec: String
    /// The sound's length in seconds, or `nil` without an audio track.
    let audioDuration: Double?
    /// The presentation time of every video frame, in order.
    let frameTimes: [Double]
    /// The decoded frames asked for, by index.
    let frames: [Int: FrameReadback]

    static func read(_ url: URL, decoding indices: Set<Int> = []) async throws -> MovieReadback {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (rate, size, formats) = try await video.load(.nominalFrameRate, .naturalSize, .formatDescriptions)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioDuration = try await audio?.load(.timeRange).duration.seconds
        let (times, frames) = try decode(video, of: asset, keeping: indices)
        let code = formats.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let codec = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii)
        return MovieReadback(duration: duration, frameRate: rate, size: size, codec: codec ?? "",
                             audioDuration: audioDuration, frameTimes: times, frames: frames)
    }

    private static func decode(_ track: AVAssetTrack, of asset: AVAsset,
                               keeping indices: Set<Int>) throws -> ([Double], [Int: FrameReadback]) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        var frames: [Int: FrameReadback] = [:]
        while let sample = output.copyNextSampleBuffer() {
            if indices.contains(times.count), let buffer = CMSampleBufferGetImageBuffer(sample) {
                frames[times.count] = FrameReadback(buffer)
            }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return (times, frames)
    }
}

/// A disk with a fixed amount of free space.
struct FakeDiskSpace: DiskSpaceChecking {
    let available: Int64?

    func availableCapacity(for url: URL) throws -> Int64? { available }
}

/// The dispatch queues a callback ran on, by label.
final class QueueLabels: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var labels: [String] { lock.withLock { recorded } }

    /// Record the label of the queue this is called on.
    func record() {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock { recorded.append(label) }
    }
}

/// A disk whose free space cannot be read; it records where it was asked.
final class UnreadableDiskSpace: DiskSpaceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var askedAbout: [URL] { lock.withLock { urls } }

    func availableCapacity(for url: URL) throws -> Int64? {
        lock.withLock { urls.append(url) }
        throw CocoaError(.fileReadNoPermission)
    }
}

/// The session-time bar, drawn slowly — so a test can cancel an export of a
/// three-second clip half-way through.
struct SlowSessionTimeBar: OverlayFrameDrawing {
    var bar = SessionTimeBar(origin: 0)
    var delay: TimeInterval = 0.015

    func prepare(for size: CGSize) {}

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        Thread.sleep(forTimeInterval: delay)
        bar.draw(frame, in: context, size: size)
    }
}

/// The files of one export test: the footage, the destination, and the scratch
/// directory the exporter is told to use (and must remove).
struct ExportSandbox {
    let directory: URL
    let destination: URL
    let scratch: URL

    init() throws {
        directory = try MediaFixtures.tempDirectory()
        destination = directory.appendingPathComponent("export.mp4")
        scratch = directory.appendingPathComponent("scratch")
    }

    /// An exporter writing through ``scratch``.
    func exporter(available: Int64? = nil, progressInterval: Duration = .milliseconds(100)) -> OverlayVideoExporter {
        let scratch = scratch
        return OverlayVideoExporter(diskSpace: FakeDiskSpace(available: available), progressInterval: progressInterval,
                                    scratchDirectory: { _ in
                                        try FileManager.default.createDirectory(at: scratch,
                                                                                withIntermediateDirectories: true)
                                        return scratch
                                    })
    }

    /// Write the synthetic footage.
    func footage(_ spec: TestMediaFactory.Spec = .init()) async throws -> URL {
        let url = directory.appendingPathComponent("footage.mp4")
        try await TestMediaFactory.writeMovie(spec, to: url)
        return url
    }

    /// Whether anything of the export is left: the destination or the scratch directory.
    var destinationExists: Bool { FileManager.default.fileExists(atPath: destination.path) }
    var scratchExists: Bool { FileManager.default.fileExists(atPath: scratch.path) }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The plan of exporting `url` with `settings`, the session at `session`.
func exportPlan(_ url: URL, range: ExportRange = .wholeFootage, offset: Double = 0,
                session: SessionTimeSpan = SessionTimeSpan(start: -100, end: 100),
                settings: ExportSettings = ExportSettings(resolution: .source)) async throws -> ExportPlan {
    let footage = try await FootageProbe.probe(url)
    let request = ExportRequest(source: url, sync: VideoSyncModel(videoDuration: footage.duration, offset: offset),
                                range: range, session: session, settings: settings)
    return try ExportPlan.make(request: request, footage: footage, timeline: .empty, encoders: .all).get()
}

/// The progress of an export, collected until it ends.
func collect(_ stream: AsyncThrowingStream<ExportProgress, Error>) async throws -> [ExportProgress] {
    var events: [ExportProgress] = []
    for try await progress in stream { events.append(progress) }
    return events
}
