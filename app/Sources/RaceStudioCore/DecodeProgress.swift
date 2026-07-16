import Foundation

/// Decode progress reported while loading a session (issue 2.5).
///
/// `fraction` is always clamped to `0...1` (non-finite input becomes `0`), and
/// folding a newer reading in with ``reduce(_:)`` never lets it decrease — so the
/// UI's progress bar only ever moves forward.
public struct DecodeProgress: Equatable, Sendable {

    /// The coarse decode stage, for an optional status label.
    public enum Phase: String, Equatable, Sendable, CaseIterable {
        case reading, decoding, finalizing, complete
    }

    /// Completed fraction in `0...1`.
    public private(set) var fraction: Double

    /// The current decode stage.
    public var phase: Phase

    public init(fraction: Double = 0, phase: Phase = .reading) {
        self.fraction = Self.clamp(fraction)
        self.phase = phase
    }

    /// Fold in a newer reading: the fraction is clamped to `0...1` and never
    /// decreases; the phase advances to the update's.
    public func reduce(_ update: DecodeProgress) -> DecodeProgress {
        DecodeProgress(fraction: max(fraction, update.fraction), phase: update.phase)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
