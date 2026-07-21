#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Guarded-delete tests for issue 6.6 — run **end-to-end across the FFI
/// boundary**: the delete is driven through the real Rust core
/// (`deleteSession`) via a Swift `DeleteChannel` spy that records every byte
/// "sent", so the refusal paths assert **zero** destructive bytes and the happy
/// path asserts exactly one frame, never retried. No live device is attached.
/// Compiled only when the xcframework is built.
@Suite struct SessionDeleteTests {

    /// A `DeleteChannel` spy: records every framed request handed to `send`, and
    /// replays a queued response from `recv`.
    final class SpyChannel: DeleteChannel {
        private(set) var sent: [Data] = []
        private var responses: [Data]
        private let lock = NSLock()
        init(response: Data) { responses = [response] }

        func send(frame: Data) {
            lock.lock(); defer { lock.unlock() }
            sent.append(frame)
        }
        func recv() -> Data {
            lock.lock(); defer { lock.unlock() }
            return responses.isEmpty ? Data() : responses.removeFirst()
        }
        var bytesSent: Int {
            lock.lock(); defer { lock.unlock() }
            return sent.reduce(0) { $0 + $1.count }
        }
    }

    /// The STCP payload checksum (16-bit LE additive sum), matching the device.
    private static func stcpChecksum(_ payload: Data) -> UInt16 {
        var sum: UInt16 = 0
        for byte in payload { sum = sum &+ UInt16(byte) }
        return sum
    }

    /// Frame a delete response: payload = `status(u16 LE) || id(u32 LE)`, wrapped
    /// in a checksum-valid STCP frame (the hypothesized 6.6 ack/reject shape).
    private static func deleteResponseFrame(status: UInt16, id: UInt32) -> Data {
        var payload = Data()
        withUnsafeBytes(of: status.littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: id.littleEndian) { payload.append(contentsOf: $0) }

        var frame = Data("<hSTCP".utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(0) // flag
        frame.append(UInt8(ascii: ">"))
        frame.append(payload)
        frame.append(Data("<STCP".utf8))
        withUnsafeBytes(of: stcpChecksum(payload).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(UInt8(ascii: ">"))
        return frame
    }

    private static func target() -> SessionInfo {
        SessionInfo(
            id: 7,
            name: "FIXTURE_SESSION",
            date: SessionDate(year: 2026, month: 7, day: 21, hour: 10, minute: 30, second: 0),
            lapCount: 12,
            sizeBytes: 4096
        )
    }
    private static func matchingConfirmation() -> DeleteConfirmation {
        DeleteConfirmation(sessionId: 7, expectedName: "FIXTURE_SESSION")
    }

    // MARK: - end-to-end across the FFI boundary

    @Test func test_delete_acked_succeeds_and_sends_one_frame() throws {
        let channel = SpyChannel(response: Self.deleteResponseFrame(status: 0, id: 7))

        try deleteSessionFile(
            target: Self.target(),
            confirmation: Self.matchingConfirmation(),
            armed: true,
            channel: channel
        )

        #expect(channel.sent.count == 1)      // exactly one delete frame
        #expect(channel.bytesSent > 0)
    }

    @Test func test_delete_reject_throws() throws {
        let channel = SpyChannel(response: Self.deleteResponseFrame(status: 1, id: 7))

        do {
            try deleteSessionFile(
                target: Self.target(),
                confirmation: Self.matchingConfirmation(),
                armed: true,
                channel: channel
            )
            Issue.record("expected deleteSession to throw on a device reject")
        } catch let error as DiscoveryError {
            guard case .DeleteRejected = error else {
                Issue.record("expected DiscoveryError.DeleteRejected, got \(error)")
                return
            }
        }
        #expect(channel.sent.count == 1, "one attempt, no blind retry")
    }

    @Test func test_delete_not_armed_sends_zero_bytes() throws {
        let channel = SpyChannel(response: Self.deleteResponseFrame(status: 0, id: 7))

        do {
            try deleteSessionFile(
                target: Self.target(),
                confirmation: Self.matchingConfirmation(),
                armed: false, // not armed
                channel: channel
            )
            Issue.record("expected an unarmed delete to throw")
        } catch let error as DiscoveryError {
            guard case .NotArmed = error else {
                Issue.record("expected DiscoveryError.NotArmed, got \(error)")
                return
            }
        }
        #expect(channel.bytesSent == 0, "NO destructive bytes were sent")
    }

    @Test func test_delete_wrong_confirmation_sends_zero_bytes() throws {
        let channel = SpyChannel(response: Self.deleteResponseFrame(status: 0, id: 7))
        let wrong = DeleteConfirmation(sessionId: 999, expectedName: "FIXTURE_SESSION")

        do {
            try deleteSessionFile(
                target: Self.target(),
                confirmation: wrong,
                armed: true,
                channel: channel
            )
            Issue.record("expected a mismatched confirmation to throw")
        } catch let error as DiscoveryError {
            guard case .ConfirmationMismatch = error else {
                Issue.record("expected DiscoveryError.ConfirmationMismatch, got \(error)")
                return
            }
        }
        #expect(channel.bytesSent == 0, "NO destructive bytes were sent")
    }
}
#endif
