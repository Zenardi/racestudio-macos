import Combine
import Foundation

/// The brain of the **Export Video with Overlay** sheet (issue 9.14).
///
/// It holds the operator's choices — what to export (``range``, and the laps
/// picked for *Selected laps*), which ``overlay``, and the output
/// ``settings`` — and answers everything the sheet shows:
///
/// - **What can be picked.** Every lap is listed (``lapItems``); one the
///   footage doesn't hold in full is disabled with the reason, and can't be
///   picked. The range menu (``rangeOptions``) disables what doesn't apply.
/// - **Whether *Export…* works** (``canExport``) and, when not, why
///   (``validationMessage(locale:)``): an unavailable range, no lap picked, or
///   an output this Mac can't encode.
/// - **A live estimate** of the duration and file size (``estimate``),
///   re-planned (``ExportPlan/make(request:footage:timeline:encoders:)``)
///   ``estimateDelay`` after the last change, so dragging through settings
///   doesn't flicker it. The sheet opens with one.
/// - **A sync warning** for a video never synced, or synced only from its
///   file date.
/// - **The file name** the save panel suggests (``suggestedFileName``).
///
/// It opens on the last-used choices (``ExportPreferences``), each falling
/// back to its default where it doesn't apply: the best lap when the footage
/// covers it, else the session; the workspace's overlay, else *Kart
/// coaching*. Pure: no AppKit, no file access.
@MainActor
public final class ExportSheetModel: ObservableObject {

    /// How long after the last change the estimate is re-planned.
    public static let estimateDelay: Duration = .milliseconds(150)

    /// What is exported.
    @Published public var range: ExportRangeChoice { didSet { changed() } }
    /// The laps *Selected laps* exports — only laps the footage holds in full.
    @Published public private(set) var pickedLaps: Set<LapID> { didSet { changed() } }
    /// The overlay burned in.
    @Published public var overlay: ExportOverlayChoice
    /// The output's resolution, codec, sound and out-of-session overlay.
    @Published public var settings: ExportSettings { didSet { changed() } }
    /// The duration and size of the export as it stands, or `nil` when it
    /// can't run — re-planned ``estimateDelay`` after each change.
    @Published public private(set) var estimate: ExportEstimate?

    /// Every reviewable lap, in session order.
    public let lapItems: [ExportLapItem]
    /// The session's fastest lap, or `nil` without a valid one.
    public let bestLap: LapID?

    private let input: ExportSheetInput
    /// What stops each range choice that can't be exported.
    private let problems: [ExportRangeChoice: ExportRangeProblem]
    private let encoders: EncoderAvailability
    private let locale: Locale
    private let scheduler: any DelayScheduling
    private var pendingEstimate: AnyCancellable?

    /// - Parameters:
    ///   - input: the footage, sync and session the sheet is opened on.
    ///   - preferences: the last-used choices.
    ///   - encoders: the encoders available; this Mac's by default.
    ///   - locale: the language of the suggested file name.
    ///   - scheduler: what debounces the estimate.
    public init(input: ExportSheetInput, preferences: ExportPreferences = ExportPreferences(),
                encoders: EncoderAvailability = .system, locale: Locale = .current,
                scheduler: any DelayScheduling = TaskDelayScheduler()) {
        self.input = input
        self.encoders = encoders
        self.locale = locale
        self.scheduler = scheduler
        let best = SessionSummaryViewModel.bestLapIndex(input.laps).map { LapID(Int(input.laps[$0].index)) }
        let times = Dictionary(input.laps.map { (LapID(Int($0.index)), $0.durationS) }, uniquingKeysWith: { a, _ in a })
        let items = input.timeline.laps.map { span in
            ExportLapItem(lap: span.lap, time: times[span.lap] ?? span.span.duration, isBest: span.lap == best,
                          coverage: input.sync.coverage(of: span.span))
        }
        lapItems = items
        bestLap = best
        let problems = Self.problems(input: input, lapItems: items)
        self.problems = problems
        let covered = Set(items.filter(\.isCovered).map(\.lap))
        let windowPicks = Set(input.selectedLaps).intersection(covered)
        pickedLaps = windowPicks.isEmpty ? Set([best].compactMap { $0 }).intersection(covered) : windowPicks
        settings = preferences.settings
        overlay = Self.overlay(preferences.overlay, hasWorkspaceOverlay: input.hasWorkspaceOverlay)
        range = Self.range(preferences.range, problems: problems)
        estimate = currentPlan().map(ExportEstimate.init(plan:))
    }

    // MARK: - Choices

    /// Pick or unpick `lap` for *Selected laps*; a lap the footage doesn't
    /// hold in full can't be picked.
    public func togglePick(_ lap: LapID) {
        guard lapItems.contains(where: { $0.lap == lap && $0.isCovered }) else { return }
        if pickedLaps.contains(lap) { pickedLaps.remove(lap) } else { pickedLaps.insert(lap) }
    }

    /// Every range choice, in menu order, each with what stops it.
    public var rangeOptions: [ExportRangeOption] {
        let best = lapItems.first(where: \.isBest)
        return ExportRangeChoice.allCases.map { ExportRangeOption(choice: $0, problem: problems[$0], bestLap: best) }
    }

    /// The overlays offered: the workspace's own when it has one, then the
    /// built-in presets.
    public var overlayOptions: [ExportOverlayChoice] {
        (input.hasWorkspaceOverlay ? [.workspace] : []) + OverlayPreset.allCases.map { .preset($0) }
    }

    /// Whether the footage has sound — the sound choice applies only then.
    public var footageHasAudio: Bool { input.footage.hasAudio }

    /// The choices to remember for the next export.
    public var preferences: ExportPreferences {
        ExportPreferences(range: range, overlay: overlay, settings: settings)
    }

    // MARK: - The export

    /// The export as it stands, or `nil` when the range holds nothing to
    /// export: no best lap, no lap picked, nothing under review.
    public var request: ExportRequest? {
        exportRange.map { ExportRequest(source: input.source, sync: input.sync, range: $0, session: input.session,
                                        settings: settings) }
    }

    /// Plan the export as it stands — what *Export…* runs.
    public func makePlan() -> Result<ExportPlan, OverlayExportError> {
        guard let request else { return .failure(.rangeOutsideFootage) }
        return ExportPlan.make(request: request, footage: input.footage, timeline: input.timeline,
                               encoders: encoders)
    }

    /// Whether *Export…* can be pressed.
    public var canExport: Bool { validationMessage(locale: locale) == nil }

    /// Why *Export…* can't be pressed, or `nil` when it can: the range's
    /// problem, no lap picked, or why the output can't be planned.
    public func validationMessage(locale: Locale = .current) -> String? {
        if let problem = problems[range] { return problem.message(locale: locale) }
        if range == .selectedLaps, pickedLaps.isEmpty { return L10n.string(.exportValidationNoLaps, locale: locale) }
        if case .failure(let error) = makePlan() {
            return ExportProgressModel.userMessage(for: error, locale: locale).title
        }
        return nil
    }

    /// The estimate as the sheet shows it, or a dash without one.
    public func estimateText(locale: Locale = .current) -> String {
        estimate?.text(locale: locale) ?? LapTimeFormatter.placeholder
    }

    /// The resolution menu's title for `resolution`: *Source* names the
    /// footage's upright size — `Source (1920 × 1080)` — the presets their
    /// height.
    public func resolutionTitle(_ resolution: ExportResolution, locale: Locale = .current) -> String {
        switch resolution {
        case .source:
            let size = input.footage.displaySize
            return L10n.format(.exportResolutionSource, locale: locale, "\(Int(size.width)) × \(Int(size.height))")
        case .p2160: return "4K (2160p)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    /// The note under the lap picker when several laps are picked: they are
    /// exported as one clip, from the first to the last.
    public func lapsHint(locale: Locale = .current) -> String? {
        let laps = pickedLaps.sorted { $0.index < $1.index }
        guard range == .selectedLaps, let first = laps.first, let last = laps.last, first != last else { return nil }
        return L10n.format(.exportLapsHint, locale: locale, SyncStatus.number(first), SyncStatus.number(last))
    }

    /// The warning for a video never synced, or synced only from its file
    /// date — `nil` once the operator has synced it.
    public func syncWarning(locale: Locale = .current) -> String? {
        switch input.status {
        case .notSynced: return L10n.string(.exportSyncNotSynced, locale: locale)
        case .estimated: return L10n.string(.exportSyncEstimated, locale: locale)
        case .anchored, .twoPoint, .autoAudio: return nil
        }
    }

    /// The layout the export draws: the workspace's (Kart coaching without
    /// one) or the chosen preset — always shown, even when the HUD is hidden
    /// in Video + Data.
    public func layout(workspace: OverlayLayout?, locale: Locale = .current) -> OverlayLayout {
        var layout: OverlayLayout
        switch overlay {
        case .workspace: layout = workspace ?? OverlayPreset.kartCoaching.layout(locale: locale)
        case .preset(let preset): layout = preset.layout(locale: locale)
        }
        layout.isEnabled = true
        return layout
    }

    // MARK: - The file name

    /// The name the save panel suggests: track, date and what is exported.
    public var suggestedFileName: String {
        let date = ExportFileName.date(logDate: input.metadata.logDate, datetimeUtc: input.metadata.datetimeUtc)
        return ExportFileName.suggested(track: input.metadata.track, date: date, subject: subject)
    }

    /// `S.Marino AR – 2026-09-25 – Lap 9 (0'40.774).mp4` — `track`, `date`
    /// (`yyyy-MM-dd`), and `lap` (0-based, named from 1) with its time.
    public nonisolated static func suggestedFileName(track: String, date: String?, lap: LapID, lapTime: Double?,
                                                     locale: Locale = .current) -> String {
        ExportFileName.suggested(track: track, date: date,
                                 subject: ExportFileName.lapSubject(lap, lapTime: lapTime, locale: locale))
    }

    // MARK: - Internals

    /// What the file name says was exported.
    private var subject: String {
        let laps: [LapID]
        switch range {
        case .wholeFootage: return L10n.string(.exportFileNameVideo, locale: locale)
        case .session: return L10n.string(.exportFileNameSession, locale: locale)
        case .selection: return L10n.string(.exportFileNameSelection, locale: locale)
        case .bestLap: laps = [bestLap].compactMap { $0 }
        case .selectedLaps: laps = pickedLaps.sorted { $0.index < $1.index }
        }
        guard let first = laps.first, let last = laps.last else {
            return L10n.string(.exportFileNameSession, locale: locale)
        }
        guard first == last else {
            return L10n.format(.exportFileNameLaps, locale: locale, SyncStatus.number(first), SyncStatus.number(last))
        }
        return ExportFileName.lapSubject(first, lapTime: lapItems.first { $0.lap == first }?.time, locale: locale)
    }

    /// The export range of the current choice, or `nil` when it holds none.
    private var exportRange: ExportRange? {
        switch range {
        case .wholeFootage: return .wholeFootage
        case .session: return .session
        case .bestLap: return bestLap.map { .laps([$0]) }
        case .selectedLaps:
            return pickedLaps.isEmpty ? nil : .laps(pickedLaps.sorted { $0.index < $1.index })
        case .selection: return input.selection.map { .span($0) }
        }
    }

    /// What stops each range choice that can't be exported, for `input` and
    /// its `lapItems`.
    private static func problems(input: ExportSheetInput,
                                 lapItems: [ExportLapItem]) -> [ExportRangeChoice: ExportRangeProblem] {
        var problems: [ExportRangeChoice: ExportRangeProblem] = [:]
        if input.sync.coverage(of: input.session) == .none { problems[.session] = .sessionNotFilmed }
        if let best = lapItems.first(where: \.isBest) {
            switch best.coverage {
            case .full: break
            case .partial: problems[.bestLap] = .bestLapPartlyFilmed
            case .none: problems[.bestLap] = .bestLapNotFilmed
            }
        } else {
            problems[.bestLap] = .noBestLap
        }
        if !lapItems.contains(where: \.isCovered) { problems[.selectedLaps] = .noCoveredLap }
        if let selection = input.selection {
            if input.sync.coverage(of: selection) == .none { problems[.selection] = .selectionNotFilmed }
        } else {
            problems[.selection] = .noSelection
        }
        return problems
    }

    /// The plan of the export as it stands, or `nil` when it can't run.
    private func currentPlan() -> ExportPlan? {
        guard problems[range] == nil, case .success(let plan) = makePlan() else { return nil }
        return plan
    }

    /// A choice changed: re-plan the estimate once the changes settle — or,
    /// when nothing can be exported now, drop it at once, so no stale figure
    /// stands beside a disabled *Export…*.
    private func changed() {
        guard validationMessage(locale: locale) == nil else {
            pendingEstimate = nil
            estimate = nil
            return
        }
        pendingEstimate = scheduler.schedule(after: Self.estimateDelay) { [weak self] in
            guard let self else { return }
            estimate = currentPlan().map(ExportEstimate.init(plan:))
        }
    }

    /// The remembered range when it applies here, else the best lap when the
    /// footage covers it, else the session.
    private static func range(_ remembered: ExportRangeChoice?,
                              problems: [ExportRangeChoice: ExportRangeProblem]) -> ExportRangeChoice {
        if let remembered, problems[remembered] == nil { return remembered }
        return problems[.bestLap] == nil ? .bestLap : .session
    }

    /// The remembered overlay when it applies here, else the workspace's own
    /// when it has one, else Kart coaching.
    private static func overlay(_ remembered: ExportOverlayChoice?, hasWorkspaceOverlay: Bool) -> ExportOverlayChoice {
        switch remembered {
        case .preset(let preset): return .preset(preset)
        case .workspace where hasWorkspaceOverlay: return .workspace
        default: return hasWorkspaceOverlay ? .workspace : .preset(.kartCoaching)
        }
    }
}
