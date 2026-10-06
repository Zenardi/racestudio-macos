import CoreGraphics
import Foundation

/// How a video track is turned to be shown upright (issue 9.13): the quarter
/// turn its `preferredTransform` applies — a phone filming in portrait stores
/// landscape frames and a 90° turn.
public enum FootageRotation: Int, CaseIterable, Sendable {
    /// Shown as stored.
    case none = 0
    /// Turned a quarter clockwise.
    case clockwise90 = 90
    /// Turned upside down.
    case upsideDown = 180
    /// Turned a quarter counter-clockwise.
    case counterclockwise90 = 270

    /// Whether the turn swaps the frame's width and height.
    public var swapsDimensions: Bool {
        self == .clockwise90 || self == .counterclockwise90
    }
}

/// The sound of a piece of footage (issue 9.13).
public struct FootageAudio: Equatable, Sendable {
    /// Samples per second.
    public let sampleRate: Double
    /// Channels (1 mono, 2 stereo, …).
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// What an export needs to know about the footage (issue 9.13) — read from
/// the file by ``FootageProbe``, but a plain value so the plan
/// (``ExportPlan``) is testable without any media.
public struct FootageInfo: Equatable, Sendable {
    /// The video track's length, in seconds.
    public let duration: Double
    /// The nominal frame rate, as an exact rational (29.97 is 30000/1001).
    public let frameRate: FrameGrid
    /// The stored frame size, before ``rotation``.
    public let naturalSize: CGSize
    /// The turn that shows the frames upright.
    public let rotation: FootageRotation
    /// The sound, or `nil` for footage without any.
    public let audio: FootageAudio?
    /// The video codec's four-character code (`avc1`, `hvc1`, …).
    public let codec: String

    public init(duration: Double, frameRate: FrameGrid, naturalSize: CGSize, rotation: FootageRotation,
                audio: FootageAudio?, codec: String) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        self.frameRate = frameRate
        self.naturalSize = naturalSize
        self.rotation = rotation
        self.audio = audio
        self.codec = codec
    }

    /// Whether the footage has sound.
    public var hasAudio: Bool { audio != nil }

    /// The frame size as shown — upright, after ``rotation``.
    public var displaySize: CGSize {
        rotation.swapsDimensions ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize
    }

    /// The number of whole frames in ``duration`` at the nominal rate.
    public var frameCount: Int {
        Int((duration * Double(frameRate.numerator) / Double(frameRate.denominator) + 1e-6).rounded(.down))
    }
}
