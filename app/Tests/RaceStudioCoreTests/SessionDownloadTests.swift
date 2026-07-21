#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Session-download tests for issue 6.5 — run **end-to-end across the FFI
/// boundary**: chunk frames are pulled through the real Rust core
/// (`downloadSession`) via a Swift `ChunkSource`, reassembled and verified, with
/// progress delivered back to a Swift `DownloadProgress`. No live device is
/// attached; the transport is a recorded replay. Compiled only when the
/// xcframework is built.
@Suite struct SessionDownloadTests {

    /// A `ChunkSource` that replays a queue of pre-framed chunks, then `nil`.
    final class RecordedChunkSource: ChunkSource {
        private var queue: [Data]
        private let lock = NSLock()
        init(_ frames: [Data]) { queue = frames }
        func nextChunk() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    /// A `DownloadProgress` that records every `(bytesDone, total)` sample.
    final class CollectingProgress: DownloadProgress {
        private(set) var events: [(UInt64, UInt64)] = []
        private let lock = NSLock()
        func onProgress(bytesDone: UInt64, total: UInt64) {
            lock.lock(); defer { lock.unlock() }
            events.append((bytesDone, total))
        }
    }

    /// The STCP payload checksum (16-bit LE additive sum), matching the device.
    private static func stcpChecksum(_ payload: Data) -> UInt16 {
        var sum: UInt16 = 0
        for byte in payload { sum = sum &+ UInt16(byte) }
        return sum
    }

    /// Frame one download chunk: payload = `offset(u32 LE) || data`, wrapped in a
    /// checksum-valid STCP frame (`docs/device/PROTOCOL.md` §3 + §6).
    private static func chunkFrame(offset: UInt32, data: Data) -> Data {
        var payload = Data()
        withUnsafeBytes(of: offset.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(data)

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

    // MARK: - end-to-end across the FFI boundary

    @Test func test_download_reassembles_and_reports_progress() throws {
        let payload = Data((0..<250).map { UInt8($0 % 256) })
        let frames = [
            Self.chunkFrame(offset: 0, data: Data(payload[0..<100])),
            Self.chunkFrame(offset: 100, data: Data(payload[100..<200])),
            Self.chunkFrame(offset: 200, data: Data(payload[200...]))
        ]
        let source = RecordedChunkSource(frames)
        let progress = CollectingProgress()
        let plan = DownloadPlan(
            sessionId: 5,
            totalLen: UInt64(payload.count),
            wholeFileChecksum: Self.stcpChecksum(payload)
        )

        let out = try downloadSessionFile(plan: plan, source: source, progress: progress)

        #expect(out == payload)
        // The foreign progress sink saw monotonic bytes reaching 100%.
        #expect(progress.events.last?.0 == UInt64(payload.count))
        #expect(progress.events.last?.1 == UInt64(payload.count))
    }

    @Test func test_download_bad_checksum_throws() throws {
        let payload = Data((0..<64).map { UInt8($0) })
        var corrupt = Self.chunkFrame(offset: 0, data: payload)
        corrupt[corrupt.count - 2] ^= 0xFF // break the trailer checksum
        // Redeliver the corrupt chunk more than the core's MAX_CHUNK_RETRIES (3,
        // in racestudio-device transfer.rs — not exposed across FFI) so the retry
        // budget is exhausted → unrecoverable. A regression would fail loudly with
        // ".MissingChunk" rather than mis-assert, so a generous count is safe.
        let source = RecordedChunkSource(Array(repeating: corrupt, count: 5))
        let progress = CollectingProgress()
        let plan = DownloadPlan(sessionId: 1, totalLen: 64, wholeFileChecksum: 0)

        do {
            _ = try downloadSessionFile(plan: plan, source: source, progress: progress)
            Issue.record("expected downloadSession to throw on unrecoverable corruption")
        } catch let error as DiscoveryError {
            guard case .ChecksumMismatch = error else {
                Issue.record("expected DiscoveryError.ChecksumMismatch, got \(error)")
                return
            }
        }
    }

    @Test func test_download_missing_chunk_throws() throws {
        let payload = Data((0..<200).map { UInt8($0 % 256) })
        // Deliver only the first half, then end-of-stream → a gap.
        let frames = [Self.chunkFrame(offset: 0, data: Data(payload[0..<100]))]
        let source = RecordedChunkSource(frames)
        let progress = CollectingProgress()
        let plan = DownloadPlan(sessionId: 1, totalLen: 200, wholeFileChecksum: 0)

        do {
            _ = try downloadSessionFile(plan: plan, source: source, progress: progress)
            Issue.record("expected downloadSession to throw on a missing chunk")
        } catch let error as DiscoveryError {
            guard case .MissingChunk = error else {
                Issue.record("expected DiscoveryError.MissingChunk, got \(error)")
                return
            }
        }
    }
}
#endif
