import Accelerate
import Foundation

/// Streaming **downmix + anti-aliased integer decimation** (issue 9.8): turns a
/// video's 44.1/48 kHz interleaved float audio into the ~8 kHz mono the engine
/// pitch estimator reads, one decoded chunk at a time — so a ten-minute clip
/// never holds its source-rate track, only one chunk plus the output.
///
/// Channels are averaged; a Blackman-windowed sinc low-pass runs through
/// Accelerate's `vDSP_desamp`, which filters and decimates in one pass. It is
/// cut at 40 % of the output rate with 24 taps per unit of factor: flat
/// (−0.02 dB) to 30 % of the output rate — 2.4 kHz at 8 kHz, the sixth
/// harmonic of the 400 Hz pitch band — and at least 55 dB down from the output
/// Nyquist on, so what folds back is buried. The filter is symmetric and centred —
/// output sample `n` sits exactly on input frame `n·factor` — so decimation
/// adds no delay for the offset estimate to trip on. Non-finite samples are
/// read as silence.
public struct PCMDecimator: Sendable {

    /// Source frames per second.
    public let sourceRate: Int
    /// Interleaved channels per frame.
    public let channels: Int
    /// Source frames per output sample — divides ``sourceRate`` exactly.
    public let factor: Int

    /// Output samples per second: `sourceRate / factor` — at or above the
    /// target, or the source rate itself when that is already lower.
    public var outputRate: Int { sourceRate / factor }

    /// Low-pass taps either side of the centre, per unit of ``factor``.
    static let halfWidthPerFactor = 12
    /// The low-pass cut-off as a fraction of the output rate.
    static let cutoffFraction = 0.40

    /// The highest source rate accepted (Hz) — above any real audio, so a
    /// corrupt format cannot size a giant filter.
    public static let maxSourceRate = 384_000
    /// The most interleaved channels accepted.
    public static let maxChannels = 64

    private let taps: [Float]
    /// Mono samples from the first one the next output still needs.
    private var buffer: [Float]
    private var inputFrames = 0
    private var emitted = 0

    /// A decimator from `sourceRate` × `channels` towards (and never under)
    /// `targetRate`, or `nil` when any of them is not positive, or the rate or
    /// channel count is beyond ``maxSourceRate`` / ``maxChannels``.
    public init?(sourceRate: Int, channels: Int, targetRate: Int) {
        guard (1...Self.maxSourceRate).contains(sourceRate), (1...Self.maxChannels).contains(channels),
              targetRate > 0 else { return nil }
        self.sourceRate = sourceRate
        self.channels = channels
        self.factor = Self.factor(sourceRate: sourceRate, targetRate: targetRate)
        self.taps = Self.lowPass(factor: factor)
        // Pre-pad half a filter of silence so output 0 is centred on frame 0.
        self.buffer = [Float](repeating: 0, count: (taps.count - 1) / 2)
    }

    /// The largest factor that divides `sourceRate` exactly and keeps the output
    /// at or above `targetRate` (`1` when the source is already at or below it).
    static func factor(sourceRate: Int, targetRate: Int) -> Int {
        var factor = max(1, sourceRate / targetRate)
        while sourceRate % factor != 0 { factor -= 1 }
        return factor
    }

    /// A unit-gain, Blackman-windowed sinc low-pass for decimating by `factor`.
    static func lowPass(factor: Int) -> [Float] {
        guard factor > 1 else { return [1] }
        let half = halfWidthPerFactor * factor
        let span = Double(2 * half)
        let cutoff = cutoffFraction / Double(factor) // cycles per source frame
        let taps = (0...2 * half).map { n -> Double in
            let x = Double(n - half)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = 2 * .pi * Double(n) / span
            return sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
        }
        let gain = taps.reduce(0, +)
        return taps.map { Float($0 / gain) }
    }

    /// Feed interleaved frames; returns the output samples they complete.
    public mutating func process(_ interleaved: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = interleaved.count / channels
        guard frames > 0, let source = interleaved.baseAddress else { return [] }
        let start = buffer.count
        buffer.append(contentsOf: repeatElement(0, count: frames))
        var scale = 1 / Float(channels)
        let channels = self.channels
        buffer.withUnsafeMutableBufferPointer { mono in
            guard let base = mono.baseAddress else { return }
            let out = base + start
            // Sum each channel's strided column into the mono run, then average.
            for channel in 0..<channels {
                vDSP_vadd(source + channel, vDSP_Stride(channels), out, 1, out, 1, vDSP_Length(frames))
            }
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(frames))
            // A decoder glitch (NaN / ∞) reads as silence, never poisons the filter.
            for index in start..<(start + frames) where !mono[index].isFinite {
                mono[index] = 0
            }
        }
        inputFrames += frames
        return drain(limit: .max)
    }

    /// End the stream: the last outputs, their filters run into silence, so
    /// the whole stream yields `ceil(frames / factor)` samples.
    public mutating func finish() -> [Float] {
        let pending = (inputFrames + factor - 1) / factor - emitted
        guard pending > 0 else { return [] }
        buffer.append(contentsOf: repeatElement(0, count: taps.count))
        return drain(limit: pending)
    }

    /// Every output whose whole filter window is buffered (at most `limit`),
    /// then drop the input no later output needs.
    private mutating func drain(limit: Int) -> [Float] {
        let length = taps.count
        guard buffer.count >= length else { return [] }
        let count = min((buffer.count - length) / factor + 1, limit)
        var out = [Float](repeating: 0, count: count)
        buffer.withUnsafeBufferPointer { input in
            taps.withUnsafeBufferPointer { filter in
                out.withUnsafeMutableBufferPointer { output in
                    guard let a = input.baseAddress, let f = filter.baseAddress, let c = output.baseAddress else {
                        return
                    }
                    vDSP_desamp(a, vDSP_Stride(factor), f, c, vDSP_Length(count), vDSP_Length(length))
                }
            }
        }
        buffer.removeFirst(count * factor)
        emitted += count
        return out
    }
}
