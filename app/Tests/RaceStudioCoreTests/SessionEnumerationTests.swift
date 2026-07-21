#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Session-enumeration tests for issue 6.4 — run **end-to-end across the FFI
/// boundary**: the captured request and recorded catalog response are driven
/// through the real Rust core (`buildSessionListRequest` / `parseSessionList`),
/// and a dated session decodes into a typed ``SessionInfo``/``SessionDate``. The
/// dated-session record layout is a documented hypothesis (see `session.rs`); no
/// live device is attached. Compiled only when the xcframework is built.
@Suite struct SessionEnumerationTests {

    /// Repo-root-relative path (up from app/Tests/RaceStudioCoreTests/).
    private static func repoFixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RaceStudioCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relative)
    }

    private static func fixture(_ relative: String) throws -> Data {
        try Data(contentsOf: repoFixture(relative))
    }

    /// Append a little-endian integer's bytes to `data`.
    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// STCP-frame a session-list payload with a valid trailer checksum — the same
    /// framing the device uses (`docs/device/PROTOCOL.md` §3).
    private static func frame(payload: Data) -> Data {
        var buf = Data("<hSTCP".utf8)
        appendLE(UInt32(payload.count), to: &buf)
        buf.append(0) // flag
        buf.append(UInt8(ascii: ">"))
        buf.append(payload)
        buf.append(Data("<STCP".utf8))
        var sum: UInt16 = 0
        for byte in payload { sum = sum &+ UInt16(byte) }
        appendLE(sum, to: &buf)
        buf.append(UInt8(ascii: ">"))
        return buf
    }

    /// A year/month/day for a synthetic session record.
    private struct SynthDate {
        let year: UInt16
        let month: UInt8
        let day: UInt8
    }

    /// A synthetic 56-byte dated session record (hypothesized layout — session.rs).
    private static func record(
        id: UInt32, date: SynthDate, laps: UInt16, size: UInt32, name: String
    ) -> Data {
        var r = [UInt8](repeating: 0, count: 56)
        r[0] = UInt8(ascii: "s"); r[1] = UInt8(ascii: "e"); r[2] = UInt8(ascii: "s")
        r[3] = 1
        for (i, b) in withUnsafeBytes(of: id.littleEndian, Array.init).enumerated() { r[4 + i] = b }
        for (i, b) in withUnsafeBytes(of: date.year.littleEndian, Array.init).enumerated() { r[8 + i] = b }
        r[10] = date.month
        r[11] = date.day
        for (i, b) in withUnsafeBytes(of: laps.littleEndian, Array.init).enumerated() { r[16 + i] = b }
        for (i, b) in withUnsafeBytes(of: size.littleEndian, Array.init).enumerated() { r[18 + i] = b }
        for (i, b) in Array(name.utf8.prefix(32)).enumerated() { r[24 + i] = b }
        return Data(r)
    }

    // MARK: - end-to-end across the FFI boundary

    @Test func test_request_matches_captured_fixture() throws {
        // The FFI-built request equals the captured catalog request byte-for-byte.
        let captured = try Self.fixture("fixtures/device/control/command_info.bin")
        #expect(sessionListRequest() == captured)
    }

    @Test func test_recorded_response_yields_empty_list() throws {
        // The recorded store was empty at capture time → an empty list, not an error.
        let response = try Self.fixture("fixtures/device/sessions/list_response.bin")
        #expect(try parseSessions(response).isEmpty)
    }

    @Test func test_dated_session_crosses_boundary_typed() throws {
        var payload = Data()
        Self.appendLE(UInt32(1), to: &payload) // count
        payload.append(Self.record(
            id: 7, date: SynthDate(year: 2026, month: 7, day: 21),
            laps: 12, size: 4_200_000, name: "Kart AM"
        ))

        let sessions = try parseSessions(Self.frame(payload: payload))

        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == 7)
        #expect(s.name == "Kart AM")
        #expect(s.lapCount == 12)
        #expect(s.sizeBytes == 4_200_000)
        // The date crosses as a typed SessionDate, not a string.
        #expect(s.date.year == 2026)
        #expect(s.date.month == 7)
        #expect(s.date.day == 21)
    }

    @Test func test_empty_frame_is_ok() throws {
        var payload = Data()
        Self.appendLE(UInt32(0), to: &payload) // count = 0
        #expect(try parseSessions(Self.frame(payload: payload)).isEmpty)
    }

    @Test func test_bad_checksum_throws() throws {
        var response = try Self.fixture("fixtures/device/sessions/list_response.bin")
        // Payload starts at offset 12 (6 magic + 4 len + 1 flag + 1 '>'); flipping any
        // payload byte must fail the checksum-first gate. Guard the index so a
        // regenerated, shorter fixture fails diagnosably rather than trapping.
        try #require(response.count > 20, "fixture too short to corrupt a payload byte")
        response[20] ^= 0xFF

        do {
            _ = try parseSessions(response)
            Issue.record("expected parseSessions to throw on a corrupt checksum")
        } catch let error as DiscoveryError {
            guard case .BadChecksum = error else {
                Issue.record("expected DiscoveryError.BadChecksum, got \(error)")
                return
            }
        }
    }
}
#endif
