import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Round-trip tests for the UniFFI decode interface (issue 1.7).
///
/// These open the real `aim_official_test.xrk` sample through the generated
/// Swift bindings, list channels (metadata only — no bulk samples), pull two
/// adjacent windows via `samples(channel:start:count:)`, and assert they stitch
/// to a single wider window — proving Swift can drive decode without copying the
/// whole session across the FFI boundary. The `.xrk` sample is git-ignored
/// (fetched by `make fixtures`); when absent the tests skip cleanly.
@Suite struct DecodeFFITests {

    /// The real sample path, or `nil` (with a skip note) when it is absent.
    private func xrkOrSkip() -> String? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url.path
    }

    @Test func testSwiftRoundtripListsAndWindows() throws {
        guard let path = xrkOrSkip() else { return }

        // open_session returns an opaque handle; channel listing carries metadata
        // only (name/unit/rate/count) — no bulk samples.
        let session = try openSession(path: path)
        let channels = session.channels()
        #expect(!channels.isEmpty, "channels listed")

        let first = channels[0]
        #expect(!first.name.isEmpty, "channel has a name")
        #expect(first.sampleCount > 4, "channel has samples to window")

        // Pull two adjacent windows and stitch them; assert they equal a single
        // wider window — no whole-session copy required.
        let k = min(UInt32(8), first.sampleCount / 2)
        let a = try session.samples(channelIndex: 0, start: 0, count: k)
        let b = try session.samples(channelIndex: 0, start: k, count: k)
        #expect(a.count == Int(k), "first window is the requested size")
        #expect(b.count == Int(k), "second window is the requested size")

        let wide = try session.samples(channelIndex: 0, start: 0, count: k * 2)
        let stitched = a + b
        #expect(stitched.count == wide.count, "stitched count matches wide window")
        for (lhs, rhs) in zip(stitched, wide) {
            #expect(lhs.timecode == rhs.timecode, "stitched timecode matches")
            #expect(lhs.value == rhs.value, "stitched value matches")
        }
    }

    @Test func testSwiftWindowOutOfRangeIsBounded() throws {
        guard let path = xrkOrSkip() else { return }
        let session = try openSession(path: path)
        let count = session.channels()[0].sampleCount

        // start past the end → empty; a bad channel index → a thrown DecodeError.
        let past = try session.samples(channelIndex: 0, start: count + 100, count: 10)
        #expect(past.isEmpty, "nothing past the end")

        #expect(throws: (any Error).self) {
            _ = try session.samples(channelIndex: 9_999, start: 0, count: 1)
        }
    }

    @Test func testSwiftOpenBadPathThrows() {
        // A nonexistent path surfaces as a thrown DecodeError, never a trap.
        #expect(throws: (any Error).self) {
            _ = try openSession(path: "/no/such/session.xrk")
        }
    }
}
