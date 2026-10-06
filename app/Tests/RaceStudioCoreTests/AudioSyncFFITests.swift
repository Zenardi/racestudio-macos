import Testing
import AVFoundation
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// The issue 9.8 auto-sync over the **real** FFI: the production estimator maps
/// the core's typed refusals, the FFI data source vends it, and the whole chain
/// — a generated WAV read by `AVAssetReader`, decimated, matched by the Rust
/// core against the public `aim_official_test.xrk` RPM — recovers a known offset.
///
/// The `.xrk` is git-ignored (fetched by `make fixtures`, and by CI); without it
/// the end-to-end test skips. Excluded from the build when the xcframework is
/// absent (`testExcludes` in `Package.swift`).
@Suite struct AudioSyncFFITests {

    private func xrkOrSkip() -> URL? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url
    }

    /// Every core refusal reads as its typed failure.
    @Test func test_core_refusals_map_to_typed_failures() {
        #expect(AudioSyncFailure(AnalysisError.AudioTooShort(message: "")) == .tooShort)
        #expect(AudioSyncFailure(AnalysisError.NoEnginePitch(message: "")) == .silentAudio)
        #expect(AudioSyncFailure(AnalysisError.NoUsableRpm(message: "")) == .noRPM)
        #expect(AudioSyncFailure(AnalysisError.MissingChannel(message: "")) == .noRPM)
        #expect(AudioSyncFailure(AnalysisError.FlatRpm(message: "")) == .flatRPM)
        #expect(AudioSyncFailure(AnalysisError.InvalidAudio(message: "")) == .estimationFailed)
        #expect(AudioSyncFailure(AnalysisError.WindowOutOfBounds(message: "")) == .estimationFailed)
    }

    /// Engine audio rendered from the public sample's RPM at a known offset is
    /// aligned to within one 29.97 fps frame, end to end.
    @MainActor
    @Test func test_the_production_chain_recovers_a_known_offset() async throws {
        guard let xrk = xrkOrSkip() else { return }
        let loaded = try await FFISessionLoader().load(xrk) { _ in }
        let analysis = AnalysisSession(session: loaded.session, dataSource: try #require(loaded.dataSource))
        let rpm = try #require(analysis.rpmChannel)
        let trace = analysis.series(channelIndex: rpm.channelIndex)
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("engine.wav")
        try await EngineSynth.render(times: trace.xs, rpm: trace.values, offset: -200, seconds: 90, to: wav)

        let coordinator = try #require(analysis.audioSyncCoordinator(source: AVAssetAudioPCMSource(url: wav)))
        let range = try #require(analysis.audioSyncSearchRange(videoDuration: 90))
        let proposal = try await coordinator.run(searchRange: range) { _ in }

        #expect(analysis.canEstimateAudioSync)
        #expect(proposal.isApplicable, "\(proposal)")
        #expect(abs((proposal.offset ?? .nan) + 200) <= 1_001.0 / 30_000.0, "\(proposal)")
    }

    /// A ten-minute clip end to end — decode, decimate, match — within budget.
    /// The issue's budget is 5 s on Apple silicon in a release build (measured
    /// ~0.9 s on the real 606 s footage); this debug, coverage-instrumented run on
    /// a ~3× slower CI runner gets a generous ceiling that still catches an
    /// algorithmic regression.
    @MainActor
    @Test func test_a_ten_minute_clip_syncs_within_budget() async throws {
        guard let xrk = xrkOrSkip() else { return }
        let loaded = try await FFISessionLoader().load(xrk) { _ in }
        let analysis = AnalysisSession(session: loaded.session, dataSource: try #require(loaded.dataSource))
        let trace = analysis.series(channelIndex: try #require(analysis.rpmChannel).channelIndex)
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("ten-minutes.wav")
        try await EngineSynth.render(times: trace.xs, rpm: trace.values, offset: -4, seconds: 590, to: wav)
        let coordinator = try #require(analysis.audioSyncCoordinator(source: AVAssetAudioPCMSource(url: wav)))
        let range = try #require(analysis.audioSyncSearchRange(videoDuration: 590))

        let start = Date()
        let proposal = try await coordinator.run(searchRange: range) { _ in }
        let elapsed = Date().timeIntervalSince(start)

        print("10-minute clip end to end (debug): \(elapsed) s → \(proposal)")
        #expect(abs((proposal.offset ?? .nan) + 4) <= 1_001.0 / 30_000.0, "\(proposal)")
        #expect(elapsed < 30, "took \(elapsed) s")
    }

    /// The local real-footage check (never in CI): set
    /// `RACESTUDIO_AUDIO_SYNC_VIDEO` and `RACESTUDIO_AUDIO_SYNC_SESSION` to an
    /// onboard clip and its `.xrk` to print the proposal and the end-to-end time.
    @MainActor
    @Test func test_local_footage_end_to_end() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let video = env["RACESTUDIO_AUDIO_SYNC_VIDEO"], let xrk = env["RACESTUDIO_AUDIO_SYNC_SESSION"] else {
            return
        }
        let start = Date()
        let loaded = try await FFISessionLoader().load(URL(fileURLWithPath: xrk)) { _ in }
        let analysis = AnalysisSession(session: loaded.session, dataSource: try #require(loaded.dataSource))
        let url = URL(fileURLWithPath: video)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let coordinator = try #require(analysis.audioSyncCoordinator(source: AVAssetAudioPCMSource(url: url)))
        let range = try #require(analysis.audioSyncSearchRange(videoDuration: duration))

        let proposal = try await coordinator.run(searchRange: range) { _ in }

        print("LOCAL FOOTAGE: \(proposal) in \(Date().timeIntervalSince(start)) s")
    }
}

/// Engine audio for the end-to-end test: four harmonics of `RPM/60`, heard at
/// session time `t − offset`, plus white noise, written as a 16 kHz mono WAV.
private enum EngineSynth {
    /// ``write(times:rpm:offset:seconds:to:)`` off the main actor — seconds of
    /// synthesis there would stall every main-actor suite running alongside.
    static func render(times: [Double], rpm: [Double], offset: Double, seconds: Double, to url: URL) async throws {
        try await Task.detached {
            try write(times: times, rpm: rpm, offset: offset, seconds: seconds, to: url)
        }.value
    }

    static func write(times: [Double], rpm: [Double], offset: Double, seconds: Double, to url: URL) throws {
        let rate = 16_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)),
              let data = buffer.floatChannelData?[0] else { throw CocoaError(.featureUnsupported) }
        var phases = [Double](repeating: 0, count: 4)
        var noise: UInt64 = 0x5EED
        var index = 0
        for i in 0..<Int(seconds * rate) {
            let sessionTime = Double(i) / rate - offset
            while index + 1 < times.count, times[index + 1] <= sessionTime { index += 1 }
            var sample = 0.0
            if index + 1 < times.count, times[index] <= sessionTime {
                let weight = (sessionTime - times[index]) / (times[index + 1] - times[index])
                let value = rpm[index] + (rpm[index + 1] - rpm[index]) * weight
                for h in phases.indices {
                    phases[h] += 2 * .pi * value / 60 * Double(h + 1) / rate
                    sample += 0.05 * sin(phases[h])
                }
            }
            noise = noise &* 6_364_136_223_846_793_005 &+ 1
            sample += 0.05 * (Double(noise >> 40) / Double(1 << 24) - 0.5)
            data[i] = Float(sample)
        }
        buffer.frameLength = AVAudioFrameCount(seconds * rate)
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                        interleaved: false).write(from: buffer)
    }
}
