import Foundation

/// Which of the two two-point anchors is being set (issue 9.7).
public enum AnchorSlot: String, CaseIterable, Sendable {
    case a
    case b
}

/// A two-point anchor as the review sets it (issue 9.7): the lap whose start it
/// was taken from, for the status line, and the session/video pair it pins.
public struct LapAnchor: Equatable, Sendable {
    public let lap: LapID
    public let anchor: SyncAnchor

    public init(lap: LapID, anchor: SyncAnchor) {
        self.lap = lap
        self.anchor = anchor
    }

    /// Where the anchor was set, laps 1-based — "set on lap 3" — the anchor
    /// button's spoken value once it is set.
    public func label(locale: Locale = .current) -> String {
        L10n.format(.videoAnchorSetOnLap, locale: locale, SyncStatus.number(lap))
    }
}

/// What became of the file-date guess when footage was attached (issue 9.7).
public enum AutoOffsetOutcome: Equatable, Sendable {
    /// The guess overlaps the session and was applied, marked estimated.
    case applied
    /// Both clocks are known, but the guess would leave the footage covering no
    /// part of the session — typically a re-exported file stamped days later.
    case implausible
    /// No guess was made: a clock is missing, there is no footage or session
    /// length to test it against, or the operator has already synced by hand.
    case unavailable

    /// What the panel tells the operator, or `nil` when there is nothing to say.
    public func message(locale: Locale = .current) -> String? {
        self == .implausible ? L10n.string(.videoMessageImplausibleDate, locale: locale) : nil
    }
}

/// The modifier a keyboard nudge needs, kept free of SwiftUI so the key map is
/// part of the tested core (issue 9.7).
public enum NudgeModifier: Equatable, Sendable {
    case none
    case shift
    case option
}

/// One fine-trim step of the sync offset (issue 9.7): a frame on `,` / `.`,
/// 0.1 s with `⇧`, 1 s with `⌥` — backward on `,`, forward on `.`.
public enum OffsetNudge: CaseIterable, Sendable {
    case frameBackward, frameForward
    case tenthBackward, tenthForward
    case secondBackward, secondForward

    /// How far the nudge moves the offset.
    public enum Step: Equatable, Sendable {
        /// Whole frames along the footage's ``FrameGrid``.
        case frames(Int)
        /// Plain seconds, not snapped to the grid.
        case seconds(Double)
    }

    /// The nudge's step, signed: backward nudges are negative.
    public var step: Step {
        switch self {
        case .frameBackward: return .frames(-1)
        case .frameForward: return .frames(1)
        case .tenthBackward: return .seconds(-0.1)
        case .tenthForward: return .seconds(0.1)
        case .secondBackward: return .seconds(-1)
        case .secondForward: return .seconds(1)
        }
    }

    /// The key that triggers it: `,` steps back, `.` steps forward.
    public var key: Character {
        switch self {
        case .frameBackward, .tenthBackward, .secondBackward: return ","
        case .frameForward, .tenthForward, .secondForward: return "."
        }
    }

    /// The modifier that picks the step size: none for a frame, `⇧` for 0.1 s,
    /// `⌥` for 1 s.
    public var modifier: NudgeModifier {
        switch self {
        case .frameBackward, .frameForward: return .none
        case .tenthBackward, .tenthForward: return .shift
        case .secondBackward, .secondForward: return .option
        }
    }

    /// The control's spoken (VoiceOver) and tooltip label.
    public func label(locale: Locale = .current) -> String {
        L10n.string(labelKey, locale: locale)
    }

    private var labelKey: L10n.Key {
        switch self {
        case .frameBackward: return .controlNudgeFrameBackward
        case .frameForward: return .controlNudgeFrameForward
        case .tenthBackward: return .controlNudgeTenthBackward
        case .tenthForward: return .controlNudgeTenthForward
        case .secondBackward: return .controlNudgeSecondBackward
        case .secondForward: return .controlNudgeSecondForward
        }
    }
}

public extension TwoPointSyncError {

    /// The rejection as a sentence the operator can act on.
    func message(locale: Locale = .current) -> String {
        switch self {
        case .missingAnchor:
            return L10n.string(.videoMessageMissingAnchor, locale: locale)
        case .anchorsTooClose:
            return L10n.string(.videoMessageAnchorsTooClose, locale: locale)
        case .rateOutOfBounds(let rate):
            let percent = (rate - 1) * 100
            let magnitude = L10n.formattedNumber(percent, fractionDigits: 2, locale: locale)
            return L10n.format(.videoMessageRateOutOfBounds, locale: locale,
                               percent > 0 ? "+" + magnitude : magnitude)
        case .nonFinite:
            return L10n.string(.videoMessageNonFinite, locale: locale)
        }
    }
}
