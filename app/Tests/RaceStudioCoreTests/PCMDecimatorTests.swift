import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 streaming **downmix + decimation** that turns a
/// video's 44.1/48 kHz stereo audio into the ~8 kHz mono the engine-pitch
/// estimator reads, chunk by chunk, without ever holding the source-rate track.
@Suite struct PCMDecimatorTests {

    /// `seconds` of a `freq` Hz sine of amplitude `amp` at `rate`, on `channels`
    /// interleaved channels (channel `c` scaled by `gains[c]`).
    private func tone(_ freq: Double, rate: Int, seconds: Double, amp: Float = 0.5,
                      gains: [Float] = [1, 1]) -> [Float] {
        let frames = Int(seconds * Double(rate))
        var out = [Float]()
        out.reserveCapacity(frames * gains.count)
        for i in 0..<frames {
            let s = amp * Float(sin(2 * .pi * freq * Double(i) / Double(rate)))
            for gain in gains { out.append(s * gain) }
        }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Zero crossings per second / 2 — the frequency of a clean sine.
    private func frequency(_ x: ArraySlice<Float>, rate: Int) -> Double {
        let crossings = zip(x, x.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(x.count) / Double(rate))
    }

    private func decimate(_ input: [Float], rate: Int, channels: Int = 2, chunk: Int = 4096) -> [Float] {
        guard var decimator = PCMDecimator(sourceRate: rate, channels: channels, targetRate: 8000) else { return [] }
        var out = [Float]()
        var start = 0
        while start < input.count {
            let end = min(input.count, start + chunk * channels)
            input[start..<end].withUnsafeBufferPointer { out += decimator.process($0) }
            start = end
        }
        return out + decimator.finish()
    }

    // MARK: - Rate

    /// The factor divides the source rate exactly, so the output rate is an
    /// integer and never under the target.
    @Test(arguments: [(48_000, 6, 8_000), (44_100, 5, 8_820), (32_000, 4, 8_000), (22_050, 2, 11_025),
                      (16_000, 2, 8_000), (8_000, 1, 8_000), (88_200, 10, 8_820), (96_000, 12, 8_000),
                      (6_000, 1, 6_000)])
    func test_factor_divides_the_source_rate(source: Int, factor: Int, output: Int) throws {
        let decimator = try #require(PCMDecimator(sourceRate: source, channels: 2, targetRate: 8_000))

        #expect(decimator.factor == factor)
        #expect(decimator.outputRate == output)
    }

    /// A rate, channel count or target that cannot work yields no decimator.
    @Test func test_unworkable_formats_are_rejected() {
        #expect(PCMDecimator(sourceRate: 0, channels: 2, targetRate: 8_000) == nil)
        #expect(PCMDecimator(sourceRate: 48_000, channels: 0, targetRate: 8_000) == nil)
        #expect(PCMDecimator(sourceRate: 48_000, channels: 2, targetRate: 0) == nil)
    }

    // MARK: - Signal

    /// A 100 Hz stereo tone at 48 kHz comes out a 100 Hz mono tone at 8 kHz, at
    /// the same level, one output sample per six input frames.
    @Test func test_decimation_preserves_a_100_hz_tone_and_the_sample_count() {
        let out = decimate(tone(100, rate: 48_000, seconds: 2), rate: 48_000)

        #expect(out.count == 16_000)
        let middle = out[2_000..<14_000]
        #expect(abs(frequency(middle, rate: 8_000) - 100) < 0.5)
        #expect(abs(rms(middle) - Float(0.5) / Float(2).squareRoot()) < 0.005)
    }

    /// Channels are averaged: a tone on one side only comes out at half level,
    /// and opposite-phase channels cancel.
    @Test func test_downmix_averages_the_channels() {
        let oneSide = decimate(tone(100, rate: 48_000, seconds: 1, gains: [1, 0]), rate: 48_000)
        let opposed = decimate(tone(100, rate: 48_000, seconds: 1, gains: [1, -1]), rate: 48_000)

        #expect(abs(rms(oneSide[1_000..<7_000]) - Float(0.25) / Float(2).squareRoot()) < 0.003)
        #expect(rms(opposed[1_000..<7_000]) < 1e-4)
    }

    /// A tone above the output Nyquist (6 kHz into a 4 kHz band) is filtered out
    /// before decimating, rather than folding back as a false 2 kHz pitch.
    @Test func test_tones_above_the_output_nyquist_do_not_alias() {
        let out = decimate(tone(6_000, rate: 48_000, seconds: 1, gains: [1]), rate: 48_000, channels: 1)

        #expect(rms(out[1_000..<7_000]) < 0.005)
    }

    /// Content just above the output Nyquist (4.4 kHz into a 4 kHz band) is
    /// held at least 55 dB down rather than folding back at 3.6 kHz.
    @Test func test_tones_just_above_the_output_nyquist_are_held_down() {
        let out = decimate(tone(4_400, rate: 48_000, seconds: 1, gains: [1]), rate: 48_000, channels: 1)

        #expect(rms(out[1_000..<7_000]) < Float(0.5) / Float(2).squareRoot() * 0.002)
    }

    /// The harmonics the pitch search reads (up to 2.4 kHz) pass at full level.
    @Test func test_the_pitch_band_passes_at_full_level() {
        let out = decimate(tone(2_400, rate: 48_000, seconds: 1, gains: [1]), rate: 48_000, channels: 1)

        #expect(abs(rms(out[1_000..<7_000]) - Float(0.5) / Float(2).squareRoot()) < 0.005)
    }

    /// The filter is zero-phase: an impulse at input frame 600 (12.5 ms) peaks
    /// at output sample 100 — no delay for the estimator to trip on.
    @Test func test_decimation_adds_no_delay() {
        var impulse = [Float](repeating: 0, count: 4_800)
        impulse[600] = 1

        let out = decimate(impulse, rate: 48_000, channels: 1)

        #expect(out.indices.max { out[$0] < out[$1] } == 100)
    }

    /// Feeding the stream in any chunk size gives the same samples.
    @Test func test_chunking_does_not_change_the_output() {
        let input = tone(137, rate: 44_100, seconds: 1)

        let whole = decimate(input, rate: 44_100, chunk: 1_000_000)
        let ragged = decimate(input, rate: 44_100, chunk: 333)

        #expect(whole.count == ragged.count)
        #expect(zip(whole, ragged).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(whole.count == (44_100 + 4) / 5)
    }

    /// Non-finite samples are read as silence, never as a poisoned stream.
    @Test func test_non_finite_samples_read_as_silence() {
        var input = tone(100, rate: 48_000, seconds: 1)
        input[1_000] = .nan
        input[2_001] = .infinity

        let out = decimate(input, rate: 48_000)

        #expect(out.allSatisfy { $0.isFinite })
    }
}
