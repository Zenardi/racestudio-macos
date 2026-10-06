import Foundation

/// The engine-sound alignment as the Rust core reports it (issue 9.8) — Core's
/// own mirror of the FFI `AudioSyncEstimate`, so the seam and its consumers
/// never touch the generated bindings.
public struct AudioSyncEstimate: Equatable, Sendable {
    /// `video time = session time + offset`, with video time counted from the
    /// first decoded audio sample (seconds).
    public let offset: Double
    /// Mean salience along the matched pitch curve (≈ 0 for chance).
    public let score: Double
    /// The winning peak over the best rival alignment ≥ 2 s away.
    public let peakRatio: Double
    /// The fitted `k` of `pitch = k·RPM` (`1/120` for a four-stroke single).
    public let pitchPerRPM: Double
    /// The core's verdict: whether the match clears both confidence thresholds.
    public let isConfident: Bool
    /// Display confidence in `0...1` — `0.5` at the threshold.
    public let confidence: Double

    public init(offset: Double, score: Double, peakRatio: Double, pitchPerRPM: Double,
                isConfident: Bool, confidence: Double) {
        self.offset = offset
        self.score = score
        self.peakRatio = peakRatio
        self.pitchPerRPM = pitchPerRPM
        self.isConfident = isConfident
        self.confidence = confidence
    }
}

/// Why no engine-sound alignment could be estimated (issue 9.8).
public enum AudioSyncFailure: Error, Equatable, Sendable, CaseIterable {
    /// The video carries no audio track.
    case noAudioTrack
    /// The audio track could not be decoded.
    case unreadableAudio
    /// The session has no usable RPM channel.
    case noRPM
    /// The video and the session overlap by under 20 s.
    case tooShort
    /// The audio is silent throughout.
    case silentAudio
    /// The RPM never changes.
    case flatRPM
    /// The match could not run for any other reason.
    case estimationFailed
    /// This build cannot estimate (no Rust core linked).
    case unsupported

    /// The failure as a sentence the operator can act on.
    public func message(locale: Locale = .current) -> String {
        L10n.string(messageKey, locale: locale)
    }

    private var messageKey: L10n.Key {
        switch self {
        case .noAudioTrack: return .videoAutoSyncNoAudio
        case .unreadableAudio: return .videoAutoSyncUnreadable
        case .noRPM: return .videoAutoSyncNoRPM
        case .tooShort: return .videoAutoSyncTooShort
        case .silentAudio: return .videoAutoSyncSilent
        case .flatRPM: return .videoAutoSyncFlatRPM
        case .estimationFailed: return .videoAutoSyncFailed
        case .unsupported: return .videoAutoSyncUnsupported
        }
    }
}

/// What an auto-sync run proposes (issue 9.8). Only a ``confident`` proposal may
/// be applied — and only when the operator confirms it; a ``weak`` one is shown
/// honestly as "No confident match".
public enum AudioSyncProposal: Equatable, Sendable {
    /// The engine sound lines up with the RPM at `offset` (the video clock), with
    /// display `confidence` in `0.5...1`.
    case confident(offset: Double, confidence: Double)
    /// The best alignment found does not stand out from its rivals; `offset` is
    /// reported for diagnostics only.
    case weak(offset: Double, confidence: Double)
    /// No alignment could be estimated.
    case unavailable(AudioSyncFailure)

    /// The proposal for `estimate`, its offset moved onto the video's clock by
    /// `audioStart` — the video time of the first decoded audio sample. A
    /// non-finite offset is no estimate at all, and the confidence is held to
    /// `0...1` whatever the core reports.
    public init(estimate: AudioSyncEstimate, audioStart: Double) {
        let offset = estimate.offset + audioStart
        guard offset.isFinite else {
            self = .unavailable(.estimationFailed)
            return
        }
        let confidence = estimate.confidence.isFinite ? min(1, max(0, estimate.confidence)) : 0
        self = estimate.isConfident
            ? .confident(offset: offset, confidence: confidence)
            : .weak(offset: offset, confidence: confidence)
    }

    /// Whether the panel may offer one-click apply.
    public var isApplicable: Bool {
        if case .confident = self { return true }
        return false
    }

    /// The proposed offset, if an alignment was estimated.
    public var offset: Double? {
        switch self {
        case .confident(let offset, _), .weak(let offset, _): return offset
        case .unavailable: return nil
        }
    }

    /// The display confidence, if an alignment was estimated.
    public var confidence: Double? {
        switch self {
        case .confident(_, let confidence), .weak(_, let confidence): return confidence
        case .unavailable: return nil
        }
    }

    /// The result's first line: where the match puts the footage, "No confident
    /// match", or why nothing could be estimated.
    public func headline(locale: Locale = .current) -> String {
        switch self {
        case .confident(let offset, _):
            return L10n.format(.videoAutoSyncMatched, locale: locale,
                               VideoSyncModel.readout(offset: offset, locale: locale))
        case .weak:
            return L10n.string(.videoAutoSyncNoMatch, locale: locale)
        case .unavailable(let failure):
            return failure.message(locale: locale)
        }
    }

    /// The result's second line, if it has one: the confidence of a match, or
    /// what to do instead of a weak one.
    public func detail(locale: Locale = .current) -> String? {
        switch self {
        case .confident:
            return confidenceText(locale: locale)
        case .weak:
            return L10n.string(.videoAutoSyncNoMatchDetail, locale: locale)
        case .unavailable:
            return nil
        }
    }

    /// The confidence as the bar speaks it — `"Confidence: 96%"` — or `nil`
    /// when nothing was estimated.
    public func confidenceText(locale: Locale = .current) -> String? {
        confidence.map {
            L10n.format(.videoAutoSyncConfidence, locale: locale, SyncStatus.percent($0, locale: locale))
        }
    }
}

/// Whether the *Auto-sync from engine sound* button can run, and if not why
/// (issue 9.8) — the reason is the button's help text.
public enum AudioSyncAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    /// What is missing, in the order the operator can fix it.
    public enum Reason: Equatable, Sendable, CaseIterable {
        /// No footage is attached.
        case noVideo
        /// The footage is still being inspected for an audio track.
        case checkingAudio
        /// The footage has no audio track.
        case noAudioTrack
        /// The session has no RPM channel.
        case noRPMChannel
        /// This build cannot estimate.
        case unsupported
    }

    /// Decide from what the panel knows: whether footage is attached, whether it
    /// has an audio track (`nil` while still checking), the session's RPM
    /// channel (`nil` when it has none), and whether an estimator is linked.
    public static func evaluate(hasVideo: Bool, hasAudioTrack: Bool?, rpmChannel: String?,
                                canEstimate: Bool) -> AudioSyncAvailability {
        guard hasVideo else { return .unavailable(.noVideo) }
        guard let hasAudioTrack else { return .unavailable(.checkingAudio) }
        guard hasAudioTrack else { return .unavailable(.noAudioTrack) }
        guard rpmChannel != nil else { return .unavailable(.noRPMChannel) }
        return canEstimate ? .available : .unavailable(.unsupported)
    }

    /// Whether the button is enabled.
    public var isAvailable: Bool { self == .available }

    /// The button's help text: what it does, or why it cannot.
    public func help(locale: Locale = .current) -> String {
        switch self {
        case .available: return L10n.string(.videoHelpAutoSync, locale: locale)
        case .unavailable(.noVideo): return L10n.string(.videoAutoSyncNoVideo, locale: locale)
        case .unavailable(.checkingAudio): return L10n.string(.videoAutoSyncChecking, locale: locale)
        case .unavailable(.noAudioTrack): return AudioSyncFailure.noAudioTrack.message(locale: locale)
        case .unavailable(.noRPMChannel): return AudioSyncFailure.noRPM.message(locale: locale)
        case .unavailable(.unsupported): return AudioSyncFailure.unsupported.message(locale: locale)
        }
    }
}
