import Foundation

/// The footage's frame grid (issue 9.7): its nominal frame rate as an exact
/// rational, `numerator / denominator` frames per second, so the sync offset can
/// be stepped **exactly one frame at a time**.
///
/// At 29.97 fps a frame lasts 1001/30000 s (33.4 ms); landing the offset on the
/// exact frame where the kart crosses the line is guesswork with a ±60 s slider
/// alone. The rate is kept as integers rather than a `CMTime` so this stays a
/// pure, AVFoundation-free value the review model can unit-test; the shell reads
/// the asset track's `nominalFrameRate` and hands it to
/// ``init(nominalFrameRate:)``.
public struct FrameGrid: Equatable, Sendable {

    /// Frames-per-second numerator, in lowest terms (`30000` for 29.97 fps).
    public let numerator: Int
    /// Frames-per-second denominator, in lowest terms (`1001` for 29.97 fps).
    public let denominator: Int

    /// The grid used when the footage's rate is unknown: 30 fps.
    public static let fallback = FrameGrid(numerator: 30, denominator: 1)

    /// The nominal rates taken at face value; anything outside is a corrupt
    /// track header, not a camera.
    static let plausibleFramesPerSecond: ClosedRange<Double> = 1...10_000

    /// How close a nominal rate must be to an integer or NTSC rate to be read as
    /// that exact rational (the asset reports a rounded `Float`).
    private static let rateTolerance = 0.001

    /// A grid of `numerator / denominator` frames per second, reduced to lowest
    /// terms. A zero or negative part — an unknown rate — gives ``fallback``.
    public init(numerator: Int, denominator: Int) {
        guard numerator > 0, denominator > 0 else {
            self = .fallback
            return
        }
        let divisor = Self.gcd(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    /// The grid for a track's `nominalFrameRate`. Integer rates (25, 30, 60) and
    /// the NTSC family (23.976, 29.97, 59.94 → `N×1000 / 1001`) are recognised as
    /// their exact rationals; any other rate is kept to the thousandth. A
    /// non-finite rate, or one outside 1…10 000 fps, gives ``fallback``.
    public init(nominalFrameRate fps: Double) {
        guard Self.plausibleFramesPerSecond.contains(fps) else {
            self = .fallback
            return
        }
        let whole = fps.rounded()
        if abs(fps - whole) < Self.rateTolerance {
            self.init(numerator: Int(whole), denominator: 1)
            return
        }
        let ntscBase = (fps * 1.001).rounded()
        if abs(fps - ntscBase / 1.001) < Self.rateTolerance {
            self.init(numerator: Int(ntscBase) * 1_000, denominator: 1_001)
            return
        }
        self.init(numerator: Int((fps * 1_000).rounded()), denominator: 1_000)
    }

    /// Frames per second, as a floating-point value (for display).
    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }

    /// The length of one frame in seconds — `denominator / numerator`.
    public var frameDuration: Double { Double(denominator) / Double(numerator) }

    /// `time` moved to the nearest frame boundary. Idempotent: a time already on
    /// the grid stays exactly put. A non-finite time is treated as `0`.
    public func snap(_ time: Double) -> Double {
        seconds(atFrame: frameIndex(nearest: time))
    }

    /// `time` moved by exactly `frames` frame durations (negative steps back).
    ///
    /// The step is never snapped: a time on the grid stays on it, and one a track
    /// anchor left between two frames keeps that frame-exact phase — snapping it
    /// would shift the anchored lap by up to half a frame, and make the first
    /// step move anywhere from half a frame to one and a half. A non-finite time
    /// is treated as `0`.
    public func step(_ time: Double, frames: Int) -> Double {
        (time.isFinite ? time : 0) + Double(frames) * frameDuration
    }

    // MARK: - Internals

    /// The index of the frame boundary nearest `time` (a whole number, kept as a
    /// `Double` so a far-off offset can never overflow an `Int`).
    private func frameIndex(nearest time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return (time * Double(numerator) / Double(denominator)).rounded()
    }

    private func seconds(atFrame index: Double) -> Double {
        index * Double(denominator) / Double(numerator)
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var (larger, smaller) = (lhs, rhs)
        while smaller != 0 { (larger, smaller) = (smaller, larger % smaller) }
        return larger
    }
}
