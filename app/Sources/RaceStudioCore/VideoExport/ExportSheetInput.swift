import Foundation

/// What the export sheet is opened on (issue 9.14): the footage and how it is
/// synced, the session's laps and span, what the window has selected, and
/// whether the workspace has an overlay of its own. Read off the Video + Data
/// view by ``VideoDataViewModel/exportSheetInput(source:footage:session:selectedLaps:hasWorkspaceOverlay:)``.
public struct ExportSheetInput: Sendable {
    /// The footage file.
    public var source: URL
    /// What the footage holds (``FootageProbe``).
    public var footage: FootageInfo
    /// The footage's alignment to the session.
    public var sync: VideoSyncModel
    /// How that alignment was made — what the sync warning reads.
    public var status: SyncStatus
    /// The laps and sectors on the session clock.
    public var timeline: LapSectorTimeline
    /// The session's laps — for the best lap and the lap times.
    public var laps: [Lap]
    /// The session's span on its clock.
    public var session: SessionTimeSpan
    /// The lap or sector under review, if any.
    public var selection: SessionTimeSpan?
    /// The laps selected in the window — the sheet's first lap picks.
    public var selectedLaps: [LapID]
    /// The session's track and date, for the file name.
    public var metadata: SessionMetadata
    /// Whether the workspace has an overlay of its own to export.
    public var hasWorkspaceOverlay: Bool

    public init(source: URL, footage: FootageInfo, sync: VideoSyncModel, status: SyncStatus,
                timeline: LapSectorTimeline, laps: [Lap], session: SessionTimeSpan, selection: SessionTimeSpan?,
                selectedLaps: [LapID], metadata: SessionMetadata, hasWorkspaceOverlay: Bool) {
        self.source = source
        self.footage = footage
        self.sync = sync
        self.status = status
        self.timeline = timeline
        self.laps = laps
        self.session = session
        self.selection = selection
        self.selectedLaps = selectedLaps
        self.metadata = metadata
        self.hasWorkspaceOverlay = hasWorkspaceOverlay
    }
}

/// One lap in the sheet's lap picker (issue 9.14).
public struct ExportLapItem: Equatable, Identifiable, Sendable {
    /// The lap.
    public let lap: LapID
    /// Its time, in seconds.
    public let time: Double
    /// Whether it is the session's fastest.
    public let isBest: Bool
    /// How much of it the footage holds; only a lap held in full can be picked.
    public let coverage: VideoCoverage

    public var id: Int { lap.index }

    /// Whether the footage holds the whole lap, so it can be picked.
    public var isCovered: Bool { coverage == .full }

    /// The picker's row: `Lap 9 · 0:40.774`.
    public func title(locale: Locale = .current) -> String {
        L10n.format(.videoLapLabel, locale: locale, SyncStatus.number(lap)) + " · "
            + LapTimeFormatter.string(from: time)
    }

    /// Why the lap can't be picked, or `nil` when it can.
    public func reason(locale: Locale = .current) -> String? {
        switch coverage {
        case .full: return nil
        case .partial: return L10n.string(.exportReasonPartlyFilmed, locale: locale)
        case .none: return L10n.string(.exportReasonNotFilmed, locale: locale)
        }
    }
}

/// Why a range choice can't be exported (issue 9.14).
public enum ExportRangeProblem: Equatable, Sendable {
    /// The footage doesn't reach the session at all.
    case sessionNotFilmed
    /// The session has no valid lap.
    case noBestLap
    /// The best lap is only partly in the footage.
    case bestLapPartlyFilmed
    /// The best lap is not in the footage.
    case bestLapNotFilmed
    /// No lap is wholly in the footage.
    case noCoveredLap
    /// Nothing is under review in Video + Data.
    case noSelection
    /// The section under review is not in the footage.
    case selectionNotFilmed

    /// The problem as the range menu says it.
    public func message(locale: Locale = .current) -> String {
        switch self {
        case .sessionNotFilmed: return L10n.string(.exportReasonSessionNotFilmed, locale: locale)
        case .noBestLap: return L10n.string(.exportReasonNoBestLap, locale: locale)
        case .bestLapPartlyFilmed: return L10n.string(.exportReasonPartlyFilmed, locale: locale)
        case .bestLapNotFilmed, .selectionNotFilmed: return L10n.string(.exportReasonNotFilmed, locale: locale)
        case .noCoveredLap: return L10n.string(.exportReasonNoCoveredLap, locale: locale)
        case .noSelection: return L10n.string(.exportReasonNoSelection, locale: locale)
        }
    }
}

/// One choice of the sheet's range menu (issue 9.14), and whether it applies.
public struct ExportRangeOption: Equatable, Identifiable, Sendable {
    /// The choice.
    public let choice: ExportRangeChoice
    /// Why it can't be exported, or `nil` when it can.
    public let problem: ExportRangeProblem?
    /// The best lap, for its title.
    let bestLap: ExportLapItem?

    public var id: ExportRangeChoice { choice }

    /// Whether the choice can be exported.
    public var isAvailable: Bool { problem == nil }

    /// The menu's title — the best lap named with its time.
    public func title(locale: Locale = .current) -> String {
        switch choice {
        case .wholeFootage: return L10n.string(.exportRangeWholeFootage, locale: locale)
        case .session: return L10n.string(.exportRangeSession, locale: locale)
        case .bestLap:
            guard let bestLap else { return L10n.string(.exportRangeBestLap, locale: locale) }
            return L10n.format(.exportRangeBestLapNamed, locale: locale, SyncStatus.number(bestLap.lap),
                               LapTimeFormatter.string(from: bestLap.time))
        case .selectedLaps: return L10n.string(.exportRangeSelectedLaps, locale: locale)
        case .selection: return L10n.string(.exportRangeSelection, locale: locale)
        }
    }

    /// Why the choice can't be exported, or `nil`.
    public func reason(locale: Locale = .current) -> String? {
        problem?.message(locale: locale)
    }
}

/// The sheet's live estimate (issue 9.14): how long the export runs, how big
/// the file is, and its frame size.
public struct ExportEstimate: Equatable, Sendable {
    /// The output's length, in seconds.
    public let duration: Double
    /// The expected file size, in bytes.
    public let bytes: Int64
    /// The output frame's width, in pixels.
    public let width: Int
    /// The output frame's height, in pixels.
    public let height: Int

    public init(plan: ExportPlan) {
        duration = plan.duration
        bytes = plan.estimatedBytes
        width = plan.outputWidth
        height = plan.outputHeight
    }

    /// `0:19 · about 30 MB · 1920 × 1080`.
    public func text(locale: Locale = .current) -> String {
        L10n.format(.exportEstimate, locale: locale,
                    ExportFormat.clock(duration, rule: .toNearestOrAwayFromZero),
                    ExportFormat.bytes(bytes, locale: locale), "\(width) × \(height)")
    }
}
