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

/// Where the white marker in a stored frame's top-left corner shows once the
/// footage is turned upright.
enum MarkerCorner: CustomStringConvertible {
    case topLeft, topRight, bottomRight, bottomLeft

    init(_ rotation: FootageRotation) {
        switch rotation {
        case .none: self = .topLeft
        case .clockwise90: self = .topRight
        case .upsideDown: self = .bottomRight
        case .counterclockwise90: self = .bottomLeft
        }
    }

    /// The corner across the frame.
    var opposite: MarkerCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        }
    }

    /// A pixel 8 px in from this corner of `frame`, well inside a 40 px marker.
    func pixel(in frame: FrameReadback) -> (x: Int, row: Int) {
        let left = 8, right = frame.width - 9, top = 8, bottom = frame.height - 9
        switch self {
        case .topLeft: return (left, top)
        case .topRight: return (right, top)
        case .bottomRight: return (right, bottom)
        case .bottomLeft: return (left, bottom)
        }
    }

    var description: String {
        switch self {
        case .topLeft: return "top-left"
        case .topRight: return "top-right"
        case .bottomRight: return "bottom-right"
        case .bottomLeft: return "bottom-left"
        }
    }
}

/// A 32 MB APFS disk image mounted as its own volume — an external drive's
/// stand-in, made with `hdiutil` and removed after the test.
struct ExternalVolume {
    let directory: URL
    let mountPoint: URL

    /// Whether this machine can make and mount a disk image at all (a locked
    /// down runner may not) — tried once; the tests that need one are skipped
    /// where it cannot, rather than failed.
    static let canMount: Bool = {
        guard let volume = try? ExternalVolume() else { return false }
        volume.detach()
        return true
    }()

    init() throws {
        directory = try MediaFixtures.tempDirectory()
        mountPoint = directory.appendingPathComponent("volume")
        let image = directory.appendingPathComponent("volume.dmg")
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Self.hdiutil(["create", "-quiet", "-size", "32m", "-fs", "APFS", "-volname", "RSExportTest",
                              image.path])
            try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func detach() {
        try? Self.hdiutil(["detach", "-quiet", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: directory)
    }

    /// Run `hdiutil` with its output discarded (issue 200): an `attach` leaves
    /// a `diskimages-helper` running that inherits hdiutil's output, and one
    /// left by a stopped run held the test log's pipe open, so the log never
    /// ended.
    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
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
