import CoreGraphics
import Foundation
@testable import RaceStudioCore

/// A premultiplied BGRA sRGB bitmap for the overlay renderer tests (issue 9.11)
/// — the renderer's own output format — read back in the **drawing space** the
/// drawers use: origin bottom-left, `y` up, pixel `(x, y)` covering
/// `x…x+1 × y…y+1`.
final class OverlayBitmap {

    /// One pixel, premultiplied, as stored.
    struct Pixel: Equatable {
        let blue: UInt8
        let green: UInt8
        let red: UInt8
        let alpha: UInt8

        var isTransparent: Bool { alpha == 0 }

        /// Whether this is `color` drawn opaque, each channel within `tolerance`.
        func matches(_ color: BrandColor, tolerance: Int = 3) -> Bool {
            func near(_ byte: UInt8, _ unit: Double) -> Bool {
                abs(Int(byte) - Int((unit * 255).rounded())) <= tolerance
            }
            return alpha == 255 && near(red, color.red) && near(green, color.green) && near(blue, color.blue)
        }

        /// Whether the pixel is mostly `color` (opaque-ish and nearer to it than
        /// `tolerance` on each channel, unpremultiplied).
        func resembles(_ color: BrandColor, tolerance: Int = 40) -> Bool {
            guard alpha > 128 else { return false }
            func straight(_ byte: UInt8) -> Int { Int(byte) * 255 / Int(alpha) }
            func near(_ byte: UInt8, _ unit: Double) -> Bool {
                abs(straight(byte) - Int((unit * 255).rounded())) <= tolerance
            }
            return near(red, color.red) && near(green, color.green) && near(blue, color.blue)
        }

        /// The pixel's sRGB colour, unpremultiplied, as a brand colour.
        var color: BrandColor {
            guard alpha > 0 else { return BrandColor(red: 0, green: 0, blue: 0, alpha: 0) }
            let scale = 255.0 / Double(alpha)
            return BrandColor(red: Double(red) * scale / 255, green: Double(green) * scale / 255,
                              blue: Double(blue) * scale / 255, alpha: Double(alpha) / 255)
        }
    }

    let width: Int
    let height: Int
    let context: CGContext

    /// A transparent bitmap.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        guard let context = OverlayRenderer.makeBitmapContext(width: width, height: height) else {
            fatalError("could not create a \(width)×\(height) bitmap")
        }
        self.context = context
    }

    /// The image drawn into a fresh transparent bitmap of its size.
    convenience init(image: CGImage) {
        self.init(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The pixels' bytes of an image in the renderer's own format, row by row
    /// from the top, read straight from its data — nothing is drawn, so
    /// reading back on many threads cannot race inside CoreGraphics.
    static func pixelBytes(of image: CGImage) -> [UInt8] {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data,
              let start = CFDataGetBytePtr(data) else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(image.width * 4 * image.height)
        let rowBytes = image.width * 4
        for row in 0..<image.height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: start + row * image.bytesPerRow, count: rowBytes))
        }
        return bytes
    }

    /// The whole bitmap as a rect.
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// The pixels' bytes, row by row from the top, without the rows' padding —
    /// only what the image shows.
    var bytes: [UInt8] {
        guard let data = context.data else { return [] }
        let start = data.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * 4 * height)
        for row in 0..<height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: start + row * context.bytesPerRow, count: width * 4))
        }
        return bytes
    }

    /// The pixel at `(x, y)` in drawing space.
    func pixel(x: Int, y: Int) -> Pixel {
        guard let data = context.data else { return Pixel(blue: 0, green: 0, red: 0, alpha: 0) }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let offset = (height - 1 - y) * context.bytesPerRow + x * 4
        return Pixel(blue: bytes[offset], green: bytes[offset + 1], red: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    /// The pixel under `point` (drawing space).
    func pixel(at point: CGPoint) -> Pixel {
        pixel(x: min(max(Int(point.x.rounded(.down)), 0), width - 1),
              y: min(max(Int(point.y.rounded(.down)), 0), height - 1))
    }

    /// Every pixel position (drawing space) that satisfies `predicate`, inside `region`.
    func positions(in region: CGRect? = nil, where predicate: (Pixel) -> Bool) -> [CGPoint] {
        let area = (region ?? bounds).intersection(bounds).integral
        guard !area.isNull, !area.isEmpty else { return [] }
        var found: [CGPoint] = []
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) where predicate(pixel(x: x, y: y)) {
                found.append(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            }
        }
        return found
    }

    /// How many pixels in `region` satisfy `predicate`.
    func count(in region: CGRect? = nil, where predicate: (Pixel) -> Bool) -> Int {
        positions(in: region, where: predicate).count
    }

    /// The mean position of the pixels in `region` that satisfy `predicate`.
    func centroid(in region: CGRect? = nil, where predicate: (Pixel) -> Bool) -> CGPoint? {
        let found = positions(in: region, where: predicate)
        guard !found.isEmpty else { return nil }
        let sum = found.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(found.count), y: sum.y / CGFloat(found.count))
    }

    /// The smallest rect holding every pixel in `region` that satisfies `predicate`.
    func bounds(in region: CGRect? = nil, where predicate: (Pixel) -> Bool) -> CGRect? {
        let found = positions(in: region, where: predicate)
        guard let first = found.first else { return nil }
        let minX = found.map(\.x).min() ?? first.x, maxX = found.map(\.x).max() ?? first.x
        let minY = found.map(\.y).min() ?? first.y, maxY = found.map(\.y).max() ?? first.y
        return CGRect(x: minX - 0.5, y: minY - 0.5, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

extension CGPoint {
    /// The distance to `other`.
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
