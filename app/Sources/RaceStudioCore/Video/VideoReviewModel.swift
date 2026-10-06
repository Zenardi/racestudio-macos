import Foundation

/// Whether the review is scoped to a whole lap or to one sector of it (9.6).
public enum VideoReviewScope: String, Equatable, Sendable {
    case lap
    case sector
}

/// What the player should do when the playhead reaches the end of the section
/// under review (issue 9.6) — decided here so the shell's periodic observer
/// holds no policy of its own.
public enum VideoPlaybackAction: Equatable, Sendable {
    /// Leave playback alone.
    case none
    /// Seek back to this playhead (the reviewed window's start) and keep playing.
    case seek(Double)
    /// Pause: the reviewed section is over.
    case stop
}

/// The analysis window's video-review brain (issue 9.6).
///
/// It answers the questions the panel and its `AVPlayer` keep asking —
/// *which* lap or sector is under review, *where* that puts the shared cursor and
/// the playhead, *whether* the footage actually covers it, and *what to do* when
/// the reviewed window runs out — over a ``LapSectorTimeline`` (the track data)
/// and a ``VideoSyncModel`` (the alignment). Since issue 9.7 it also owns how the
/// alignment is made and trusted: frame-accurate trimming, two-point
/// (offset + rate) sync, the plausibility-gated file-date guess, and the
/// ``SyncStatus`` the status line shows.
///
/// No AVKit and no playback state: the shell owns the player and applies these
/// decisions, exactly as the 9.5 split between ``VideoSyncModel`` and its view.
/// `@MainActor` because the SwiftUI panel reads it on the main actor (the package
/// targets macOS 13, where `@Observable` is unavailable).
@MainActor
public final class VideoReviewModel: ObservableObject {

    /// The laps and sectors placed on the session clock.
    @Published public private(set) var timeline: LapSectorTimeline

    /// The live session↔video alignment both directions read.
    @Published public private(set) var sync: VideoSyncModel

    /// The lap under review, or `nil` while the operator scrubs freely.
    @Published public private(set) var selectedLap: LapID?

    /// The split under review within ``selectedLap``, or `nil` for whole-lap review.
    @Published public private(set) var selectedSplitID: Int?

    /// Whether reaching the end of the reviewed section replays it.
    @Published public var loops: Bool = false

    /// How the footage is aligned (issue 9.7) — the status line's first half, and
    /// what a save records alongside the offset and rate.
    @Published public private(set) var status: SyncStatus = .notSynced

    /// The footage's frame grid, so a frame step moves exactly one frame
    /// (issue 9.7). 30 fps until the asset's nominal rate is known.
    @Published public private(set) var frameGrid: FrameGrid = .fallback

    /// The two-point anchors set so far (issue 9.7).
    @Published public private(set) var anchors: [AnchorSlot: LapAnchor] = [:]

    public init(timeline: LapSectorTimeline = .empty,
                sync: VideoSyncModel = VideoSyncModel(videoDuration: 0)) {
        self.timeline = timeline
        self.sync = sync
    }

    // MARK: - Footage

    /// Whether any footage is attached and playable.
    public var hasVideo: Bool { !sync.isEmpty }

    /// Seed the footage length once the asset has loaded, keeping whatever
    /// alignment (offset and rate) the operator already set.
    public func setVideoDuration(_ seconds: Double) {
        sync = VideoSyncModel(videoDuration: seconds, offset: sync.offset, rate: sync.rate)
    }

    /// Seed the frame grid from the asset's nominal frame rate (issue 9.7).
    public func setFrameRate(_ nominalFrameRate: Double) {
        frameGrid = FrameGrid(nominalFrameRate: nominalFrameRate)
    }

    /// Re-align the footage to `offset` seconds (the fine-trim slider). Trimming
    /// footage nobody aligned — or a file-date guess — is a sync by hand; trimming
    /// an anchored sync refines it and keeps its laps.
    public func setOffset(_ offset: Double) {
        sync = sync.withOffset(offset)
        if status == .notSynced || status == .estimated { status = .anchored(lap: nil) }
    }

    /// Move the offset `frames` frames along the ``frameGrid`` (issue 9.7) — the
    /// result is always on the grid.
    public func stepOffset(frames: Int) {
        setOffset(frameGrid.step(sync.offset, frames: frames))
    }

    /// Move the offset by exactly `seconds` (issue 9.7). A non-finite step is
    /// ignored.
    public func stepOffset(seconds: Double) {
        guard seconds.isFinite else { return }
        setOffset(sync.offset + seconds)
    }

    /// Apply one keyboard nudge (`,` / `.`, with `⇧` or `⌥`).
    public func nudge(_ nudge: OffsetNudge) {
        switch nudge.step {
        case .frames(let frames): stepOffset(frames: frames)
        case .seconds(let seconds): stepOffset(seconds: seconds)
        }
    }

    /// The span the fine-trim slider covers, bracketing the current alignment.
    public var trimRange: ClosedRange<Double> { sync.trimRange }

    /// Align the footage so the **section under review** starts on the frame at
    /// `playhead` — the track-aware sync: scrub to where the lap actually begins,
    /// anchor, done. Returns `false` (changing nothing) without footage, without
    /// a selection, or when the playhead is not a real time, rather than silently
    /// mis-syncing. A two-point clock ``VideoSyncModel/rate`` is kept: the new
    /// anchor moves the offset, and the drift correction still holds.
    @discardableResult
    public func anchorSelection(toPlayhead playhead: Double) -> Bool {
        guard hasVideo, let lap = selectedLap, let span = selectedSpan, playhead.isFinite else { return false }
        sync = sync.aligned(sessionTime: span.start, toPlayhead: playhead)
        status = .anchored(lap: lap)
        return true
    }

    /// Apply the wall-clock first guess from the session's and the video's start
    /// instants — but only when it is plausible (issue 9.7): the footage must then
    /// overlap the session's `0...sessionDuration`. An applied guess is marked
    /// ``SyncStatus/estimated``.
    ///
    /// Nothing changes unless the outcome is ``AutoOffsetOutcome/applied``. A file
    /// date never overrides the operator's own sync (re-linking a moved file keeps
    /// the alignment it was saved with), and the raw guess is only consulted to
    /// tell a missing clock (`.unavailable`) from a date that does not fit
    /// (`.implausible`) — it is never applied unchecked.
    @discardableResult
    public func applyAutoOffset(sessionStartEpoch: Double, videoStartEpoch: Double,
                                sessionDuration: Double) -> AutoOffsetOutcome {
        guard status == .notSynced || status == .estimated, hasVideo,
              sessionDuration.isFinite, sessionDuration > 0,
              VideoSyncModel.autoOffset(sessionStartEpoch: sessionStartEpoch,
                                        videoStartEpoch: videoStartEpoch) != nil else { return .unavailable }
        guard let offset = sync.plausibleAutoOffset(sessionStartEpoch: sessionStartEpoch,
                                                    videoStartEpoch: videoStartEpoch,
                                                    sessionDuration: sessionDuration) else { return .implausible }
        sync = sync.withOffset(offset)
        status = .estimated
        return .applied
    }

    // MARK: - Two-point sync (issue 9.7)

    /// Pin anchor `slot` to the frame at `playhead`, against the start of the
    /// section under review. Returns `false` (setting nothing) without footage,
    /// a selection or a real playhead.
    @discardableResult
    public func setAnchor(_ slot: AnchorSlot, playhead: Double) -> Bool {
        guard hasVideo, let lap = selectedLap, let span = selectedSpan, playhead.isFinite else { return false }
        anchors[slot] = LapAnchor(lap: lap, anchor: SyncAnchor(sessionTime: span.start, videoTime: playhead))
        return true
    }

    /// Solve offset and rate from anchors A and B so both land exactly on their
    /// frames. On any failure — a missing anchor, anchors too close, an implied
    /// rate no camera drifts to — the previous sync and status are kept.
    @discardableResult
    public func applyTwoPointSync() -> Result<TwoPointSync.Solution, TwoPointSyncError> {
        guard let first = anchors[.a], let second = anchors[.b] else { return .failure(.missingAnchor) }
        let result = TwoPointSync.solve(anchorA: first.anchor, anchorB: second.anchor)
        if case .success(let solution) = result {
            sync = VideoSyncModel(videoDuration: sync.videoDuration, offset: solution.offset, rate: solution.rate)
            status = .twoPoint(lapA: first.lap, lapB: second.lap)
        }
        return result
    }

    // MARK: - Status + persistence (issue 9.7)

    /// Which laps the aligned footage covers in full — the status line's second
    /// half. Follows every sync action, since it reads the live ``sync``.
    public var coverageSummary: CoverageSummary { CoverageSummary.make(timeline: timeline, sync: sync) }

    /// The panel's status line, e.g. "Synced on lap 3 + lap 14 · footage covers
    /// laps 2–15 (14 of 16)".
    public func statusLine(locale: Locale = .current) -> String {
        status.statusLine(coverage: coverageSummary, locale: locale)
    }

    /// Bring back the alignment a saved workspace carries — offset, rate and
    /// status — keeping the footage length already loaded.
    public func restore(_ attachment: VideoAttachment) {
        sync = VideoSyncModel(videoDuration: sync.videoDuration, offset: attachment.offset, rate: attachment.rate)
        status = attachment.status
        anchors = [:]
    }

    /// The offset readout, to the millisecond in the locale's digits — a
    /// 29.97 fps frame step reads as 0.033 s — plus the clock rate once a
    /// two-point sync solved one: `"+12.500 s ×1.000083"`.
    public func offsetReadout(locale: Locale = .current) -> String {
        let sign = sync.offset < 0 ? "−" : "+"
        let offset = sign + L10n.formattedNumber(abs(sync.offset), fractionDigits: 3, locale: locale) + " s"
        guard sync.rate != 1 else { return offset }
        return offset + " ×" + L10n.formattedNumber(sync.rate, fractionDigits: 6, locale: locale)
    }

    /// `attachment` re-stamped with the sync in force, for saving.
    public func stamped(_ attachment: VideoAttachment) -> VideoAttachment {
        attachment.withSync(offset: sync.offset, rate: sync.rate, status: status)
    }

    /// Forget the footage and everything about its alignment, so the next video
    /// starts unsynced.
    public func detachVideo() {
        sync = VideoSyncModel(videoDuration: 0)
        status = .notSynced
        frameGrid = .fallback
        anchors = [:]
    }

    // MARK: - Selection

    /// Whether a whole lap or a single sector is under review.
    public var scope: VideoReviewScope { selectedSplitID == nil ? .lap : .sector }

    /// Review the whole of `lap`. An unknown lap is ignored, leaving the current
    /// review intact rather than blanking the panel.
    public func select(lap: LapID) {
        guard let span = timeline.lapSpan(lap) else { return }
        selectedLap = span.lap
        selectedSplitID = nil
    }

    /// Review one sector of one lap — a click in the review grid. An unknown lap
    /// or split is ignored, as above.
    public func select(lap: LapID, splitID: Int) {
        guard let sector = timeline.sector(lap: lap, splitID: splitID) else { return }
        apply(sector)
    }

    /// Stop reviewing a section and return the player to free scrubbing.
    public func clearSelection() {
        selectedLap = nil
        selectedSplitID = nil
    }

    /// The session-time window under review, or `nil` when nothing is selected.
    public var selectedSpan: SessionTimeSpan? {
        guard let lap = selectedLap else { return nil }
        if let splitID = selectedSplitID { return timeline.sector(lap: lap, splitID: splitID)?.span }
        return timeline.lapSpan(lap)?.span
    }

    /// The section under review, named the way the readout names it —
    /// `"Lap 2"` or `"Lap 2 · S1"`.
    public var selectedLabel: String? {
        guard let lap = selectedLap else { return nil }
        if let splitID = selectedSplitID, let sector = timeline.sector(lap: lap, splitID: splitID) {
            return Self.label(lap: lap, sector: sector.name)
        }
        return timeline.lapSpan(lap).map { Self.label(lap: $0.lap, sector: nil) }
    }

    /// The lap and sector the cursor is passing through at `time`, named for the
    /// panel's readout, or `nil` outside every lap.
    public func label(atSessionTime time: Double) -> String? {
        guard let location = timeline.location(atSessionTime: time) else { return nil }
        return Self.label(lap: location.lap, sector: location.sector?.name)
    }

    // MARK: - Seeking + playback

    /// The session time the shared cursor moves to for the current review.
    public var cursorTarget: Double? { selectedSpan?.start }

    /// The playhead the player seeks to for the current review, or `nil` when
    /// there is no footage to seek.
    public var seekTarget: Double? { videoWindow?.lowerBound }

    /// The playhead window the reviewed section occupies, or `nil` without a
    /// selection or without footage.
    public var videoWindow: ClosedRange<Double>? {
        guard hasVideo, let span = selectedSpan else { return nil }
        return sync.videoRange(for: span)
    }

    /// How much of the reviewed section the footage holds.
    public var coverage: VideoCoverage {
        guard let span = selectedSpan else { return .none }
        return sync.coverage(of: span)
    }

    /// Whether the reviewed section has footage behind it to play.
    public var canPlaySelection: Bool { coverage != .none }

    /// What the player should do with the playhead at `playhead`: nothing while
    /// the section is still running, then either replay it (looping) or stop.
    public func playbackAction(atPlayhead playhead: Double) -> VideoPlaybackAction {
        guard canPlaySelection, playhead.isFinite,
              let window = videoWindow, playhead >= window.upperBound else { return .none }
        return loops ? .seek(window.lowerBound) : .stop
    }

    // MARK: - Navigation

    /// Review the next sector, rolling into the following lap at a lap's end.
    public func nextSector() { stepSector(by: 1) }

    /// Review the previous sector, rolling back into the preceding lap.
    public func previousSector() { stepSector(by: -1) }

    /// Review the next lap. In sector scope the **same split** is held, so the
    /// operator can watch one corner lap after lap — the core comparison.
    public func nextLap() { stepLap(by: 1) }

    /// Review the previous lap, holding the split as ``nextLap()`` does.
    public func previousLap() { stepLap(by: -1) }

    // MARK: - Timeline

    /// Re-seed the timeline after the laps or the split layout changed (the 8.11
    /// split-count control), keeping the review where it still exists: a vanished
    /// split falls back to whole-lap review, a vanished lap clears the selection.
    public func update(timeline: LapSectorTimeline) {
        self.timeline = timeline
        guard let lap = selectedLap, timeline.lapSpan(lap) != nil else {
            clearSelection()
            return
        }
        if let splitID = selectedSplitID, timeline.sector(lap: lap, splitID: splitID) == nil {
            selectedSplitID = nil
        }
    }

    // MARK: - Internals

    private static func label(lap: LapID, sector: String?) -> String {
        // Laps read 1-based everywhere in the UI, matching the lap picker.
        let base = "Lap \(lap.index + 1)"
        guard let sector else { return base }
        return "\(base) · \(sector)"
    }

    private func apply(_ sector: SectorSpan) {
        selectedLap = sector.lap
        selectedSplitID = sector.splitID
    }

    /// Walk the session's sectors in track order. From a whole-lap review this
    /// enters that lap's own first (or last) sector; from no review at all it
    /// starts at the session's first (or last), so the control is never dead.
    private func stepSector(by delta: Int) {
        let all = timeline.sectors
        guard !all.isEmpty else { return }

        if let lap = selectedLap, let splitID = selectedSplitID,
           let current = all.firstIndex(where: { $0.lap == lap && $0.splitID == splitID }) {
            let next = current + delta
            guard all.indices.contains(next) else { return }
            apply(all[next])
            return
        }
        if let lap = selectedLap, let span = timeline.lapSpan(lap), !span.sectors.isEmpty {
            apply(delta >= 0 ? span.sectors[0] : span.sectors[span.sectors.count - 1])
            return
        }
        apply(delta >= 0 ? all[0] : all[all.count - 1])
    }

    private func stepLap(by delta: Int) {
        guard !timeline.laps.isEmpty else { return }
        guard let lap = selectedLap,
              let current = timeline.laps.firstIndex(where: { $0.lap == lap }) else {
            let fallback = timeline.laps[delta >= 0 ? 0 : timeline.laps.count - 1]
            select(lap: fallback.lap)
            return
        }
        let next = current + delta
        guard timeline.laps.indices.contains(next) else { return }
        let target = timeline.laps[next]
        // Hold the section under review across the lap change when it exists there.
        if let splitID = selectedSplitID,
           let sector = target.sectors.first(where: { $0.splitID == splitID }) {
            apply(sector)
        } else {
            select(lap: target.lap)
        }
    }
}
