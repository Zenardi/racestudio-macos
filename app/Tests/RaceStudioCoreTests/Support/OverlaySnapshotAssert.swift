import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RaceStudioCore

/// Golden-image comparison for the overlay renderer (issue 9.11).
///
/// A render is compared with `fixtures/overlay/golden/<name>.png` after both go
/// through the same PNG encode/decode, pixel by pixel: a pixel *differs* when
/// any channel is off by more than ``channelTolerance``, and the render matches
/// when at most ``pixelTolerance`` of the pixels differ — slack for CoreText
/// anti-aliasing differences between macOS versions, far below a moved widget
/// or a changed number.
///
/// - `RECORD_OVERLAY_GOLDENS=1` writes the render as the golden (unchanged
///   pixels are not rewritten); recorded goldens are reviewed in the PR.
/// - `OVERLAY_SNAPSHOT_ARTIFACTS=<dir>` also writes every render, and a diff
///   image for each mismatch, to `<dir>` — CI uploads it, so a golden that a
///   runner renders differently can be inspected (and, if need be, recorded
///   from the runner's own output).
enum OverlaySnapshotAssert {

    /// The size every golden is rendered at.
    static let size = CGSize(width: 1280, height: 720)
    /// How far a channel may be off (out of 255) before its pixel differs.
    static let channelTolerance = 2
    /// The share of pixels that may differ.
    static let pixelTolerance = 0.005

    /// The outcome of comparing two images of one size.
    struct Comparison {
        let differing: Int
        let total: Int
        let largestDelta: Int
        let diff: CGImage?

        var differingShare: Double { total == 0 ? 1 : Double(differing) / Double(total) }
        var matches: Bool { differingShare <= pixelTolerance }
    }

    static var goldenDirectory: URL {
        FixtureLoader.fixturesDir().appendingPathComponent("overlay").appendingPathComponent("golden")
    }

    /// Check `image` against the golden `name`, recording or reporting as configured.
    static func assertMatches(_ image: CGImage, named name: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let environment = ProcessInfo.processInfo.environment
        let golden = goldenDirectory.appendingPathComponent(name + ".png")
        let rendered = try decode(try encode(image))
        let artifacts = environment["OVERLAY_SNAPSHOT_ARTIFACTS"].map { URL(fileURLWithPath: $0) }
        if let artifacts { try write(rendered, to: artifacts.appendingPathComponent(name + ".png")) }

        let stored = try? decode(Data(contentsOf: golden))
        if environment["RECORD_OVERLAY_GOLDENS"] == "1" {
            if stored.map({ compare(rendered, $0).differing > 0 }) ?? true { try write(rendered, to: golden) }
            print("recorded overlay golden \(golden.path)")
            return
        }
        guard let stored else {
            Issue.record("No golden \(golden.path) — run with RECORD_OVERLAY_GOLDENS=1 to record it",
                         sourceLocation: sourceLocation)
            return
        }
        let comparison = compare(rendered, stored)
        if !comparison.matches, let artifacts, let diff = comparison.diff {
            try write(diff, to: artifacts.appendingPathComponent(name + ".diff.png"))
        }
        #expect(comparison.matches,
                """
                \(name): \(comparison.differing) of \(comparison.total) pixels differ \
                (\(String(format: "%.3f", comparison.differingShare * 100))%, largest channel delta \
                \(comparison.largestDelta)) — limit \(pixelTolerance * 100)%
                """, sourceLocation: sourceLocation)
    }

    /// Compare two images pixel by pixel; the diff marks differing pixels in magenta.
    static func compare(_ lhs: CGImage, _ rhs: CGImage) -> Comparison {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return Comparison(differing: lhs.width * lhs.height, total: lhs.width * lhs.height, largestDelta: 255,
                              diff: nil)
        }
        let leftBitmap = OverlayBitmap(image: lhs)
        let left = leftBitmap.bytes, right = OverlayBitmap(image: rhs).bytes
        let stride = leftBitmap.context.bytesPerRow
        let marks = OverlayBitmap(width: lhs.width, height: lhs.height)
        var differing = 0, largest = 0
        marks.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))
        for row in 0..<lhs.height {
            for column in 0..<lhs.width {
                var delta = 0
                for channel in 0..<4 {
                    let offset = row * stride + column * 4 + channel
                    delta = max(delta, abs(Int(left[offset]) - Int(right[offset])))
                }
                largest = max(largest, delta)
                guard delta > channelTolerance else { continue }
                differing += 1
                marks.context.fill(CGRect(x: column, y: lhs.height - 1 - row, width: 1, height: 1))
            }
        }
        return Comparison(differing: differing, total: lhs.width * lhs.height, largestDelta: largest,
                          diff: marks.context.makeImage())
    }

    // MARK: - PNG

    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw SnapshotError.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError.encoding }
        return data as Data
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SnapshotError.decoding }
        return image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(image).write(to: url)
    }

    enum SnapshotError: Error {
        case encoding, decoding
    }
}
