import Foundation

/// The estimator seam of auto-sync (issue 9.8): match mono PCM against the
/// session's RPM channel. Production runs the Rust core over the live session
/// handle (`FFIAudioSyncEstimator`); tests substitute a fake, so the
/// coordinator is covered without the xcframework.
public protocol AudioSyncEstimating: Sendable {
    /// Estimate the offset of `pcm` (mono, `sampleRate` Hz, its own clock
    /// starting at 0) against `rpmChannel`, searching `searchRange` seconds.
    ///
    /// - Throws: an ``AudioSyncFailure`` when the core refuses (too short,
    ///   silent, flat or missing RPM, …).
    func estimate(pcm: [Float], sampleRate: Int, rpmChannel: String,
                  searchRange: ClosedRange<Double>) throws -> AudioSyncEstimate
}

/// Where an auto-sync run is (issue 9.8), for the panel's progress overlay.
public enum AudioSyncPhase: Equatable, Sendable {
    /// Decoding the footage's audio, `0...1` of the way through.
    case reading(Double)
    /// Matching the engine sound against the RPM.
    case matching
}

/// Runs one *Auto-sync from engine sound* (issue 9.8): decode the footage's
/// audio, match it against the session's RPM, and propose an offset on the
/// video's clock. It never applies anything — the operator confirms a
/// ``AudioSyncProposal/confident(offset:confidence:)`` proposal.
public struct AudioSyncCoordinator: Sendable {

    /// The rate the audio is decimated towards before matching.
    public static let targetRate = 8_000

    private let source: AudioPCMSource
    private let estimator: AudioSyncEstimating
    private let rpmChannel: String

    public init(source: AudioPCMSource, estimator: AudioSyncEstimating, rpmChannel: String) {
        self.source = source
        self.estimator = estimator
        self.rpmChannel = rpmChannel
    }

    /// Decode, then match, reporting each ``AudioSyncPhase``. Every failure is a
    /// ``AudioSyncProposal/unavailable(_:)`` proposal; only cancellation throws.
    ///
    /// - Parameter searchRange: the offsets (video clock, seconds) to consider —
    ///   see ``searchRange(videoDuration:sessionSpan:)``.
    /// - Throws: `CancellationError` when the calling task is cancelled, checked
    ///   between audio chunks and around the match. A cancelled run changes
    ///   nothing.
    public func run(searchRange: ClosedRange<Double>,
                    progress: @escaping @Sendable (AudioSyncPhase) -> Void) async throws -> AudioSyncProposal {
        let pcm: MonoPCM
        do {
            pcm = try await source.monoPCM(targetRate: Self.targetRate) { progress(.reading($0)) }
        } catch let failure as AudioSyncFailure {
            return .unavailable(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(.unreadableAudio)
        }
        try Task.checkCancellation()
        progress(.matching)
        // The estimator works on the clip's own clock; the search window and
        // the result move by where the decoded audio starts on the video's.
        let window = (searchRange.lowerBound - pcm.startTime)...(searchRange.upperBound - pcm.startTime)
        let proposal: AudioSyncProposal
        do {
            let estimate = try estimator.estimate(pcm: pcm.samples, sampleRate: pcm.sampleRate,
                                                  rpmChannel: rpmChannel, searchRange: window)
            proposal = AudioSyncProposal(estimate: estimate, audioStart: pcm.startTime)
        } catch let failure as AudioSyncFailure {
            proposal = .unavailable(failure)
        } catch {
            proposal = .unavailable(.estimationFailed)
        }
        try Task.checkCancellation()
        return proposal
    }

    /// The offsets worth searching: every alignment that puts any part of the
    /// session (`sessionSpan`, session seconds) on the footage — from the
    /// session's end at video time 0 to its start at the clip's end. Never
    /// inverted, whatever the input.
    public static func searchRange(videoDuration: Double, sessionSpan: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = -sessionSpan.upperBound
        return lower...max(lower, videoDuration - sessionSpan.lowerBound)
    }
}
