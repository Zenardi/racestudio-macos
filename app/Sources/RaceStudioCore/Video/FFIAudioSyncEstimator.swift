#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Production ``AudioSyncEstimating`` (issue 9.8): the Rust core's
/// `estimate_audio_sync` over a live `SessionHandle`, its estimate mapped into
/// Core's ``AudioSyncEstimate`` and its refusals into ``AudioSyncFailure``.
///
/// Available only when `RaceStudioFFI.xcframework` has been built.
/// `@unchecked Sendable` because the opaque handle is immutable here and the
/// Rust estimator is thread-safe (as `FFIExpressionEvaluator`).
public struct FFIAudioSyncEstimator: AudioSyncEstimating, @unchecked Sendable {
    private let session: SessionHandle

    public init(session: SessionHandle) {
        self.session = session
    }

    public func estimate(pcm: [Float], sampleRate: Int, rpmChannel: String,
                         searchRange: ClosedRange<Double>) throws -> AudioSyncEstimate {
        do {
            let estimate = try session.estimateAudioSync(
                rpmChannel: rpmChannel, pcm: pcm, sampleRate: UInt32(clamping: sampleRate),
                minOffsetS: searchRange.lowerBound, maxOffsetS: searchRange.upperBound)
            return AudioSyncEstimate(offset: estimate.offsetS, score: estimate.score,
                                     peakRatio: estimate.peakRatio, pitchPerRPM: estimate.pitchPerRpm,
                                     isConfident: estimate.confident, confidence: estimate.confidence)
        } catch let error as AnalysisError {
            throw AudioSyncFailure(error)
        }
    }
}

extension AudioSyncFailure {
    /// Translate the FFI's `AnalysisError` from an audio-sync call. Every case
    /// is named, so a new core refusal must be mapped here before it builds.
    init(_ error: AnalysisError) {
        switch error {
        case .AudioTooShort: self = .tooShort
        case .NoEnginePitch: self = .silentAudio
        case .NoUsableRpm, .MissingChannel: self = .noRPM
        case .FlatRpm: self = .flatRPM
        case .InvalidAudio, .WindowOutOfBounds, .EmptyLap, .DistanceNotMonotonic, .EmptyRange,
             .InvalidExpression, .LapOutOfRange:
            self = .estimationFailed
        }
    }
}
#endif
