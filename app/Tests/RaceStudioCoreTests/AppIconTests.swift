import Testing
import Foundation

/// Validates the committed macOS **AppIcon** asset catalog (issue 7.4, #142).
///
/// The DoD is "all required sizes (16–512 pt @1x/@2x) present, no missing-slot
/// warnings." This proves it structurally, without Xcode: the `.appiconset`'s
/// `Contents.json` must declare every required `mac` slot, each referenced PNG
/// must exist, and each PNG's *actual* pixel dimensions (read from the IHDR
/// header) must match its slot — so a missing or mis-sized icon can't ship. The
/// catalog is located from this test file's own source path, so the check is
/// independent of the working directory.
@Suite struct AppIconTests {

    private var appiconset: URL {
        URL(fileURLWithPath: #filePath)   // …/app/Tests/RaceStudioCoreTests/AppIconTests.swift
            .deletingLastPathComponent()  // RaceStudioCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("AppIcon/Assets.xcassets/AppIcon.appiconset")
    }

    /// Every macOS AppIcon slot: (point size, scale). The @2x of one size and the
    /// @1x of the next share a pixel count but are distinct, required slots.
    private static let requiredSlots: [(size: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
        (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
    ]

    private func filename(size: Int, scale: Int) -> String {
        scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    }

    @Test func test_contents_json_declares_every_required_macos_slot() throws {
        let data = try Data(contentsOf: appiconset.appendingPathComponent("Contents.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = try #require(json?["images"] as? [[String: Any]])

        for slot in Self.requiredSlots {
            let match = images.first {
                ($0["idiom"] as? String) == "mac"
                    && ($0["size"] as? String) == "\(slot.size)x\(slot.size)"
                    && ($0["scale"] as? String) == "\(slot.scale)x"
            }
            #expect(match != nil, "Contents.json missing slot \(slot.size)pt@\(slot.scale)x")
            #expect(match?["filename"] as? String == filename(size: slot.size, scale: slot.scale))
        }
        #expect(images.count == Self.requiredSlots.count, "unexpected extra/duplicate slots")
    }

    @Test func test_every_slot_png_exists_at_the_correct_pixel_size() throws {
        for slot in Self.requiredSlots {
            let expected = slot.size * slot.scale
            let file = appiconset.appendingPathComponent(filename(size: slot.size, scale: slot.scale))
            #expect(FileManager.default.fileExists(atPath: file.path), "missing \(file.lastPathComponent)")
            let (width, height) = try Self.pngPixelSize(file)
            #expect(width == expected && height == expected,
                    "\(file.lastPathComponent) is \(width)x\(height), expected \(expected)x\(expected)")
        }
    }

    /// Reads a PNG's pixel dimensions straight from its IHDR chunk — 8-byte
    /// signature, 4-byte length, "IHDR", then width @16 and height @20 as
    /// big-endian `UInt32` — so no image framework is needed and the check is pure.
    private static func pngPixelSize(_ url: URL) throws -> (Int, Int) {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 24 else {
            throw ValidationError.truncated(url.lastPathComponent)
        }
        func be32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        return (be32(16), be32(20))
    }

    private enum ValidationError: Error { case truncated(String) }
}
