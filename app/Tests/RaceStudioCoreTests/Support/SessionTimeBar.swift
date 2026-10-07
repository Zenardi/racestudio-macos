import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
@testable import RaceStudioCore

/// The test-only overlay of the export tests (issue 9.13): one bar along the
/// top of the frame whose **length encodes the session time** of the frame it
/// was drawn for — `(t − origin) × pixelsPerSecond`, in whole pixels — so a
/// frame read back from an export says exactly which session time its overlay
/// showed.
///
/// The bar is white when the frame carries data (a speed) and pure blue when
/// it does not — the "no data" overlay outside the session.
struct SessionTimeBar: OverlayFrameDrawing {
    /// The session time drawn as an empty bar.
    var origin: Double
    var pixelsPerSecond = 90.0

    /// The bar's rows, counted from the top of the frame.
    static let rows = 10..<30

    func prepare(for size: CGSize) {}

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        context.clear(CGRect(origin: .zero, size: size))
        let ink = frame.speed == nil ? CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                                     : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        context.setFillColor(ink)
        context.fill(CGRect(x: 0, y: size.height - CGFloat(Self.rows.upperBound),
                            width: CGFloat(length(at: frame.time)), height: CGFloat(Self.rows.count)))
    }

    /// The bar's length, in pixels, for session time `t`.
    func length(at t: Double) -> Int {
        max(Int(((t - origin) * pixelsPerSecond).rounded()), 0)
    }

    /// A timeline whose only channel is a speed logged at 20 Hz over
    /// `start…end` of session time: frames inside carry data, frames outside
    /// none.
    static func timeline(from start: Double, to end: Double) async throws -> TelemetryTimeline {
        let samples = stride(from: start, through: end, by: 0.05).map { DataSample(time: $0, value: 20) }
        let channel = Channel(name: "GPS Speed", unit: "m/s", sampleRateHz: 20, decimals: 1,
                              sampleCount: UInt32(samples.count))
        let session = Session(metadata: SessionFixture.make().metadata, channels: [channel], laps: [])
        return try await TelemetryTimeline.load(session: session, source: FakeSessionDataSource(banks: [samples]))
    }
}

/// A pixel read back from a frame, unpremultiplied as stored opaque.
struct FramePixel: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var isBar: Bool { red > 200 && green > 200 && blue > 200 }
    var isNoDataBar: Bool { blue > 200 && red < 60 && green < 60 }

    /// The source frame index the pixel's colour encodes, if it is a frame colour.
    var frameIndex: Int? {
        TestMediaFactory.frameIndex(red: UInt8(clamping: red), green: UInt8(clamping: green),
                                    blue: UInt8(clamping: blue))
    }

    func isNear(_ other: FramePixel, tolerance: Int = 2) -> Bool {
        abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance
    }
}

/// A frame read back as rows from the top, to measure the session-time bar
/// and read the source colour beside it.
struct FrameReadback {
    let width: Int
    let height: Int
    private let pixels: (_ x: Int, _ row: Int) -> FramePixel

    /// A BGRA pixel buffer.
    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = CVPixelBufferGetBaseAddress(buffer).map {
            Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: UInt8.self), count: rowBytes * height))
        } ?? []
        self.width = width
        self.height = height
        pixels = { x, row in
            let offset = row * rowBytes + x * 4
            return FramePixel(red: Int(bytes[offset + 2]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset]))
        }
    }

    /// A decoded image, drawn into a BGRA bitmap **in its own colour space** —
    /// the raw values the frame was encoded with, no colour conversion.
    init(_ image: CGImage) {
        let width = image.width, height = image.height, rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: rowBytes, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        pixels = { x, row in
            let offset = row * rowBytes + x * 4
            return FramePixel(red: Int(bytes[offset + 2]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset]))
        }
    }

    func pixel(x: Int, row: Int) -> FramePixel { pixels(x, row) }

    /// The bar's length: bar pixels from the left edge along its middle row.
    func barLength(where isBar: (FramePixel) -> Bool = { $0.isBar }) -> Int {
        let row = (SessionTimeBar.rows.lowerBound + SessionTimeBar.rows.upperBound) / 2
        return (0..<width).first { !isBar(pixel(x: $0, row: row)) } ?? width
    }

    /// The source colour, read in the bottom-right corner — away from every overlay.
    var sourcePixel: FramePixel { pixel(x: width - 4, row: height - 4) }
}

/// Pixel buffers for the compositor tests.
enum TestPixelBuffers {

    /// An IOSurface-backed BGRA buffer filled with frame `index`'s colour.
    static func frame(_ index: Int, width: Int = 320, height: Int = 180, marker: Bool = false) -> CVPixelBuffer? {
        guard let buffer = empty(width: width, height: height) else { return nil }
        TestMediaFactory.fill(buffer, frame: index, marker: marker)
        return buffer
    }

    /// An IOSurface-backed BGRA buffer, contents undefined.
    static func empty(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ] as CFDictionary, &buffer)
        return buffer
    }

    /// The colour frame `index` is filled with.
    static func colour(ofFrame index: Int) -> FramePixel {
        let colour = TestMediaFactory.colour(ofFrame: index)
        return FramePixel(red: Int(colour.red), green: Int(colour.green), blue: Int(colour.blue))
    }
}
