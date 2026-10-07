import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Reading what an export needs to know about a piece of footage (issue 9.13)
/// — its frame rate, size, length, rotation and sound — from synthetic files
/// written in the test.
@Suite struct FootageProbeTests {

    private func movie(_ spec: TestMediaFactory.Spec = .init(), in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("footage.mp4")
        try await TestMediaFactory.writeMovie(spec, to: url)
        return url
    }

    /// A 30 fps clip reports its exact rate, size, length, sound and codec.
    @Test func test_a_30_fps_clip_is_described() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = try await FootageProbe.probe(try await movie(in: dir))

        #expect(info.frameRate == FrameGrid(numerator: 30, denominator: 1))
        #expect(info.naturalSize == CGSize(width: 320, height: 180))
        #expect(abs(info.duration - 3) < 1e-3)
        #expect(info.frameCount == 90)
        #expect(info.audio == FootageAudio(sampleRate: 48_000, channels: 1))
        #expect(info.rotation == .none)
        #expect(info.codec == "avc1")
    }

    /// A 29.97 fps clip reports the NTSC rational, and its 90 frames last 3.003 s.
    @Test func test_a_29_97_fps_clip_reports_the_ntsc_rate() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = TestMediaFactory.Spec(frameRate: FrameGrid(numerator: 30_000, denominator: 1_001))

        let info = try await FootageProbe.probe(try await movie(spec, in: dir))

        #expect(info.frameRate == FrameGrid(numerator: 30_000, denominator: 1_001))
        #expect(abs(info.duration - 3.003) < 1e-3)
        #expect(info.frameCount == 90)
    }

    /// A clip without sound reports none.
    @Test func test_a_silent_clip_has_no_audio() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = try await FootageProbe.probe(try await movie(TestMediaFactory.Spec(audio: false), in: dir))

        #expect(info.audio == nil)
        #expect(!info.hasAudio)
    }

    /// Portrait phone footage — landscape frames turned a quarter — is shown upright.
    @Test func test_rotated_footage_reports_its_rotation() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let info = try await FootageProbe.probe(try await movie(TestMediaFactory.Spec(rotation: .clockwise90),
                                                                in: dir))

        #expect(info.rotation == .clockwise90)
        #expect(info.displaySize == CGSize(width: 180, height: 320))
    }

    /// An audio-only file has no video to export.
    @Test func test_an_audio_only_file_has_no_video_track() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sound.m4a")
        try await TestMediaFactory.writeAudioOnly(to: url)

        await #expect(throws: OverlayExportError.noVideoTrack) { try await FootageProbe.probe(url) }
    }

    /// A missing file, or one that is not media, is unreadable.
    @Test func test_a_missing_or_corrupt_file_is_unreadable() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupt = dir.appendingPathComponent("corrupt.mp4")
        try Data(repeating: 0x5A, count: 4_096).write(to: corrupt)

        await #expect(throws: OverlayExportError.sourceUnreadable) {
            try await FootageProbe.probe(dir.appendingPathComponent("missing.mp4"))
        }
        await #expect(throws: OverlayExportError.sourceUnreadable) { try await FootageProbe.probe(corrupt) }
    }

    /// A cancelled probe stops as a cancel, not as unreadable footage.
    @Test func test_a_cancelled_probe_reports_cancelled() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await movie(in: dir)

        let probe = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FootageProbe.probe(url)
        }

        await #expect(throws: OverlayExportError.cancelled) { try await probe.value }
    }
}

/// The quarter turn a track matrix applies (issue 9.13).
@Suite struct FootageRotationTests {

    @Test func test_the_camera_matrices_map_to_their_quarter_turns() {
        for rotation in FootageRotation.allCases {
            let matrix = TestMediaFactory.transform(for: rotation, width: 320, height: 180)

            #expect(FootageRotation(transform: matrix) == rotation)
        }
    }

    /// A matrix a hair off a quarter turn — float noise in the file — still
    /// reads as that turn.
    @Test func test_float_noise_is_rounded_to_the_nearest_quarter_turn() {
        let noisy = CGAffineTransform(rotationAngle: .pi / 2 + 1e-4)

        #expect(FootageRotation(transform: noisy) == .clockwise90)
        #expect(FootageRotation(transform: CGAffineTransform(a: 1, b: 1e-9, c: 0, d: 1, tx: 0, ty: 0)) == .none)
    }

    /// Only a quarter turn swaps the frame's sides.
    @Test func test_only_a_quarter_turn_swaps_the_sides() {
        #expect(FootageRotation.clockwise90.swapsDimensions)
        #expect(FootageRotation.counterclockwise90.swapsDimensions)
        #expect(!FootageRotation.none.swapsDimensions)
        #expect(!FootageRotation.upsideDown.swapsDimensions)
    }
}
