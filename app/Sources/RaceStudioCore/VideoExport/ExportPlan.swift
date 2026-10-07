import CoreGraphics
import CoreMedia
import Foundation

/// An overlay export resolved and checked before anything is encoded (issue
/// 9.13): the exact footage frames to export, the output size, the bit rates
/// and the estimated file size.
///
/// Pure: no AVFoundation, no file access — the footage is described by a
/// ``FootageInfo`` — so the export sheet can re-plan on every change to show
/// a live estimate, and every rule is unit-tested.
///
/// - **Range:** the request's range in session time is mapped onto the footage
///   through the sync (`video = session × rate + offset`), clamped to the
///   footage, and snapped to whole frames: the plan exports the frames whose
///   presentation time lies in `[start, end)`.
/// - **Size:** a resolution preset scales the upright frame's short edge to
///   its height, keeping the aspect; footage is never upscaled, and both
///   dimensions are rounded down to even numbers (4:2:0 chroma).
/// - **Bit rate:** a fixed number of bits per output pixel per frame for the
///   codec (``ExportCodec/bitsPerPixel``), so the encoder's average rate — and
///   the estimate — follow the output size and frame rate.
public struct ExportPlan: Equatable, Sendable {
    /// What was asked for.
    public let request: ExportRequest
    /// The footage it was planned against.
    public let footage: FootageInfo
    /// The index of the first footage frame exported.
    public let firstFrame: Int
    /// How many frames are exported.
    public let frameCount: Int
    /// The session time the exported footage covers: its first frame's
    /// session time to its end's.
    public let sessionSpan: SessionTimeSpan
    /// The output frame's width, in pixels (even).
    public let outputWidth: Int
    /// The output frame's height, in pixels (even).
    public let outputHeight: Int
    /// The encoder's average video bit rate, in bits per second.
    public let videoBitRate: Int
    /// The AAC bit rate, in bits per second; `0` when the output has no audio.
    public let audioBitRate: Int
    /// The expected size of the output file, in bytes.
    public let estimatedBytes: Int64

    /// Whether the output carries the footage's sound.
    public var includesAudio: Bool { audioBitRate > 0 }

    /// The output frame's size, in pixels.
    public var outputSize: CGSize { CGSize(width: outputWidth, height: outputHeight) }

    /// The output's length, in seconds — whole frames at the footage's rate.
    public var duration: Double {
        Double(frameCount) * Double(footage.frameRate.denominator) / Double(footage.frameRate.numerator)
    }

    /// The exported frames on the footage's clock, frame-exact.
    public var sourceRange: CMTimeRange {
        CMTimeRange(start: time(ofFrames: firstFrame), duration: time(ofFrames: frameCount))
    }

    /// The free space the export needs: room for the file **twice**, each copy
    /// with a 10% margin. The writer's fast-start pass (`moov` ahead of
    /// `mdat`, so a shared file starts playing before it has downloaded)
    /// rewrites the finished file into a second copy, so for a moment both are
    /// on disk.
    public var requiredBytes: Int64 { 2 * (estimatedBytes + estimatedBytes / 10) }

    /// Plan `request` against `footage`.
    ///
    /// - Parameters:
    ///   - timeline: the session's laps, for ``ExportRange/laps(_:)``.
    ///   - encoders: the encoders available; this Mac's by default.
    /// - Returns: the plan, or ``OverlayExportError/rangeOutsideFootage`` when
    ///   the range holds no frame of the footage (an empty or unknown lap
    ///   selection, a reversed or non-finite span, or one the footage does not
    ///   reach), or ``OverlayExportError/unsupportedOutput(_:)`` when the
    ///   output cannot be encoded.
    public static func make(request: ExportRequest, footage: FootageInfo, timeline: LapSectorTimeline,
                            encoders: EncoderAvailability = .system) -> Result<ExportPlan, OverlayExportError> {
        guard let video = videoRange(of: request, footage: footage, timeline: timeline),
              let frames = frames(in: video, of: footage) else { return .failure(.rangeOutsideFootage) }
        let size: (width: Int, height: Int)
        switch outputSize(for: footage, settings: request.settings, encoders: encoders) {
        case .success(let fitted): size = fitted
        case .failure(let error): return .failure(error)
        }
        return .success(ExportPlan(request: request, footage: footage, frames: frames, size: size))
    }

    // MARK: - Internals

    private init(request: ExportRequest, footage: FootageInfo, frames: Range<Int>, size: (width: Int, height: Int)) {
        self.request = request
        self.footage = footage
        self.firstFrame = frames.lowerBound
        self.frameCount = frames.count
        self.outputWidth = size.width
        self.outputHeight = size.height
        let grid = footage.frameRate
        let seconds = { (frame: Int) in Double(frame) * Double(grid.denominator) / Double(grid.numerator) }
        sessionSpan = SessionTimeSpan(start: request.sync.cursorTime(forVideoTime: seconds(frames.lowerBound)),
                                      end: request.sync.cursorTime(forVideoTime: seconds(frames.upperBound)))
        let fps = min(grid.framesPerSecond, Self.bitRateFrameRateCap)
        let pixels = Double(size.width * size.height)
        videoBitRate = max(Int((pixels * fps * request.settings.codec.bitsPerPixel).rounded()), Self.minimumBitRate)
        audioBitRate = Self.audioBitRate(footage.audio, settings: request.settings)
        let payload = Double(videoBitRate + audioBitRate) * Double(frames.count) * Double(grid.denominator)
            / Double(grid.numerator) / 8
        estimatedBytes = Int64((payload * Self.containerOverhead).rounded(.up)) + Self.containerHeaderBytes
    }

    /// The frame rate above which the bit rate stops growing: high-frame-rate
    /// footage needs fewer bits per frame.
    private static let bitRateFrameRateCap = 60.0
    /// The lowest average video bit rate planned.
    private static let minimumBitRate = 300_000
    /// The MP4 container's share on top of the media: sample tables and headers.
    private static let containerOverhead = 1.01
    private static let containerHeaderBytes: Int64 = 16_384
    /// How far below a frame boundary a time may fall and still count as on
    /// it — the slack of floating-point session-to-video arithmetic.
    private static let frameEpsilon = 1e-6

    private func time(ofFrames frames: Int) -> CMTime {
        CMTime(value: CMTimeValue(frames) * CMTimeValue(footage.frameRate.denominator),
               timescale: CMTimeScale(footage.frameRate.numerator))
    }

    /// The request's range on the footage's clock, unclamped — or `nil` for a
    /// range that names no time at all.
    private static func videoRange(of request: ExportRequest, footage: FootageInfo,
                                   timeline: LapSectorTimeline) -> (start: Double, end: Double)? {
        let span: SessionTimeSpan
        switch request.range {
        case .wholeFootage: return (0, footage.duration)
        case .session: span = request.session
        case .span(let custom): span = custom
        case .laps(let laps):
            let windows = laps.compactMap { timeline.lapSpan($0)?.span }
            guard let start = windows.map(\.start).min(), let end = windows.map(\.end).max() else { return nil }
            span = SessionTimeSpan(start: start, end: end)
        }
        guard span.start.isFinite, span.end.isFinite, span.end > span.start else { return nil }
        return (request.sync.unclampedVideoTime(forCursorTime: span.start),
                request.sync.unclampedVideoTime(forCursorTime: span.end))
    }

    /// The footage frames whose presentation time lies in `video`, clamped to
    /// the footage — or `nil` when there are none.
    private static func frames(in video: (start: Double, end: Double), of footage: FootageInfo) -> Range<Int>? {
        let rate = Double(footage.frameRate.numerator) / Double(footage.frameRate.denominator)
        let start = max(video.start, 0), end = min(video.end, footage.duration)
        guard end > start else { return nil }
        let first = Int((start * rate - frameEpsilon).rounded(.up))
        let last = min(Int((end * rate - frameEpsilon).rounded(.up)), footage.frameCount)
        return last > first ? first..<last : nil
    }

    /// The output frame for `settings`, or why it cannot be encoded.
    private static func outputSize(for footage: FootageInfo, settings: ExportSettings,
                                   encoders: EncoderAvailability) -> Result<(width: Int, height: Int),
                                                                              OverlayExportError> {
        let codec = settings.codec
        guard encoders.supports(codec) else { return .failure(.unsupportedOutput(.codecUnavailable(codec))) }
        let upright = footage.displaySize
        let shortEdge = Double(min(upright.width, upright.height))
        let scale = settings.resolution.shortEdge.map { shortEdge > 0 ? min(1, Double($0) / shortEdge) : 1 } ?? 1
        let width = even(Double(upright.width) * scale), height = even(Double(upright.height) * scale)
        guard min(width, height) >= ExportCodec.minimumEdge else {
            return .failure(.unsupportedOutput(.dimensionsTooSmall(width: width, height: height)))
        }
        guard max(width, height) <= codec.maximumEdge, width * height <= codec.maximumPixels else {
            return .failure(.unsupportedOutput(.dimensionsTooLarge(width: width, height: height, codec: codec)))
        }
        return .success((width, height))
    }

    /// `pixels` rounded down to an even whole number (`0` for a non-finite or
    /// negative size).
    private static func even(_ pixels: Double) -> Int {
        guard pixels.isFinite, pixels > 0 else { return 0 }
        return Int((pixels + frameEpsilon) / 2) * 2
    }

    /// The AAC rate for the footage's sound: stereo for two channels or more,
    /// mono otherwise — `0` when the sound is dropped or there is none.
    private static func audioBitRate(_ audio: FootageAudio?, settings: ExportSettings) -> Int {
        guard settings.audio == .keep, let audio else { return 0 }
        return audio.channels >= 2 ? 128_000 : 64_000
    }
}
