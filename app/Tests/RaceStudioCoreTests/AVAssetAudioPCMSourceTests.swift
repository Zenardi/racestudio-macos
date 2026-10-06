import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 production audio reader: `AVAssetReader` decodes the
/// footage's audio to float PCM, which is downmixed and decimated chunk by chunk
/// into the ~8 kHz mono the engine-pitch estimator reads. Every file is
/// generated in the test.
@Suite struct AVAssetAudioPCMSourceTests {

    /// Zero crossings per second — the frequency of a clean sine.
    private func frequency(_ x: ArraySlice<Float>, rate: Int) -> Double {
        let crossings = zip(x, x.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(x.count) / Double(rate))
    }

    /// A stereo 48 kHz 100 Hz tone comes out a mono 8 kHz 100 Hz tone with one
    /// sample per six source frames, starting at video time 0, and the read
    /// reports its progress up to the end.
    @Test func test_decimation_and_downmix_preserve_a_100_hz_tone() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 2)
        let progress = ProgressLog()

        let pcm = try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { progress.record($0) }

        #expect(pcm.sampleRate == 8_000)
        #expect(pcm.samples.count == 16_000)
        #expect(pcm.startTime == 0)
        #expect(abs(frequency(pcm.samples[2_000..<14_000], rate: 8_000) - 100) < 0.5)
        #expect(progress.values.last.map { $0 > 0.9 } == true)
        #expect(progress.values == progress.values.sorted())
    }

    /// Progress is reported in whole percents, each once — at most a hundred
    /// updates however many chunks the decoder delivers.
    @Test func test_progress_is_reported_in_whole_distinct_percents() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 20)
        let progress = ProgressLog()

        _ = try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { progress.record($0) }

        let percents = progress.values.map { $0 * 100 }
        #expect(!percents.isEmpty && percents.count <= 101)
        #expect(percents.allSatisfy { abs($0 - $0.rounded()) < 1e-9 })
        #expect(zip(percents, percents.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// A clip short enough to decode in one chunk still honours a cancel made
    /// while it was read.
    @Test func test_cancelling_during_a_one_chunk_read_throws_cancellation() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blip.wav")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 0.05)

        let read = Task {
            try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) { _ = try await read.value }
    }

    /// Compressed audio (AAC, as cameras record it) decodes the same way.
    @Test func test_aac_audio_decodes_to_the_same_tone() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.m4a")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 2, rate: 44_100)

        let pcm = try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { _ in }

        #expect(pcm.sampleRate == 8_820)
        #expect(abs(Double(pcm.samples.count) - 2 * 8_820) < 0.02 * 2 * 8_820)
        #expect(abs(frequency(pcm.samples[2_000..<14_000], rate: 8_820) - 100) < 1)
    }

    /// A file with audio says so; a video-only movie and a non-media file do not.
    @Test func test_has_audio_track_tells_audio_from_none() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("tone.wav")
        let movie = dir.appendingPathComponent("silent.mov")
        let text = dir.appendingPathComponent("notes.mov")
        try MediaFixtures.writeTone(to: tone, freq: 100, seconds: 0.5)
        try await MediaFixtures.writeSilentMovie(to: movie)
        try Data("not a movie".utf8).write(to: text)

        #expect(await AVAssetAudioPCMSource.hasAudioTrack(at: tone))
        #expect(await !AVAssetAudioPCMSource.hasAudioTrack(at: movie))
        #expect(await !AVAssetAudioPCMSource.hasAudioTrack(at: text))
    }

    /// Reading footage without audio is a typed failure, not an empty clip.
    @Test func test_reading_a_video_without_audio_fails_typed() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("silent.mov")
        let text = dir.appendingPathComponent("notes.mov")
        try await MediaFixtures.writeSilentMovie(to: movie)
        try Data("not a movie".utf8).write(to: text)

        await #expect(throws: AudioSyncFailure.noAudioTrack) {
            _ = try await AVAssetAudioPCMSource(url: movie).monoPCM(targetRate: 8_000) { _ in }
        }
        await #expect(throws: AudioSyncFailure.unreadableAudio) {
            _ = try await AVAssetAudioPCMSource(url: text).monoPCM(targetRate: 8_000) { _ in }
        }
    }

    /// A file whose audio header promises samples it does not hold reads as
    /// unreadable, never as an empty clip.
    @Test func test_a_truncated_file_is_unreadable() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cut.wav")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 1)
        let whole = try Data(contentsOf: url)
        try whole.prefix(64).write(to: url)

        await #expect(throws: AudioSyncFailure.self) {
            _ = try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { _ in }
        }
    }

    /// Cancelling mid-read stops at the next chunk with `CancellationError`.
    @Test func test_cancelling_mid_read_throws_cancellation() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.wav")
        try MediaFixtures.writeTone(to: url, freq: 100, seconds: 10)

        let read = Task {
            // The first progress report cancels the reading task itself.
            try await AVAssetAudioPCMSource(url: url).monoPCM(targetRate: 8_000) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        await #expect(throws: CancellationError.self) { _ = try await read.value }
    }
}

/// A thread-safe record of progress reports.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
