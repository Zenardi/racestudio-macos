import Combine
import Foundation

/// What the shell applies after one displayed video frame (issue 9.12).
public struct VideoDataTick: Equatable, Sendable {
    /// The session time to drive the shared cursor to, or `nil` when the
    /// footage is not driving it (paused, or no footage).
    public let cursorTime: Double?
    /// What to do with the player at the end of the window under review.
    public let action: VideoPlaybackAction

    public init(cursorTime: Double?, action: VideoPlaybackAction) {
        self.cursorTime = cursorTime
        self.action = action
    }
}

/// The brain of the **Video + Data** view (issue 9.12): the synced footage, a
/// live telemetry HUD over it, the lap strip plot and the track map — all on
/// one clock.
///
/// It composes the ``VideoReviewModel`` (laps, sectors, sync, play windows) with
/// the session's ``TelemetryTimeline`` and answers what every pane shows:
///
/// - **Playing**, the playhead drives: each displayed frame
///   (``tick(playhead:isPlaying:)``) maps the playhead through the sync to a
///   session time, samples the frame there with a sequential cursor, and hands
///   back the cursor time to drive and the end-of-window action.
/// - **Paused**, the cursor drives: a scrub of the plot or a click on the map
///   (``follow(cursorTime:isPlaying:)``) shows the frame there and hands back
///   the playhead to seek. The two directions never run at once — the 9.5 rule
///   — so they cannot feed back.
///
/// ``currentFrame`` is published only when what the HUD shows changes, so a
/// repeated playhead invalidates nothing. Where the footage doesn't reach the
/// cursor, ``showsNoFootage`` raises the player's plate while the HUD, plot and
/// map keep working on telemetry alone.
///
/// No AVKit, no drawing: the shell owns the player and the HUD layer and
/// applies these answers. `@MainActor` because the panel reads it there.
@MainActor
public final class VideoDataViewModel: ObservableObject {

    /// The laps, sectors, sync and play windows — shared with the sync bar.
    public let review: VideoReviewModel

    /// The session's telemetry, or `nil` until it is loaded.
    @Published public private(set) var telemetry: TelemetryTimeline?

    /// What the HUD shows: the frame at the session time on show, or `nil`
    /// before any. Republished only when its readings change, so its ``TelemetryFrame/time``
    /// is the instant those readings were first seen.
    @Published public private(set) var currentFrame: TelemetryFrame?

    /// The lap the strip plot and the map show: the one picked, else the one the
    /// cursor is in (the last one, between laps).
    @Published public private(set) var plotLap: LapID?

    /// Speed and RPM across ``plotLap``, or `nil` before the telemetry is in.
    @Published public private(set) var stripPlot: LapStripPlot?

    /// ``plotLap``'s racing line for the track map, or `nil` without a GPS track.
    @Published public private(set) var lapMap: TrackMapModel?

    /// How much footage there is at the session time on show.
    @Published public private(set) var coverageAtCursor: VideoCoverage = .none

    /// The session time on show, or `nil` before any. Not published: the panes
    /// read the cursor itself, and the frame publishes what changes.
    public private(set) var displayedTime: Double?

    private var samplingCursor = SamplingCursor()
    private var track: [GPSTrackPoint] = []
    private var loadGeneration = 0
    private var syncWatch: AnyCancellable?

    public init(review: VideoReviewModel) {
        self.review = review
        // A re-sync moves the footage under the cursor: judge it again at once.
        syncWatch = review.$sync.sink { [weak self] sync in
            self?.refreshCoverage(sync: sync)
        }
    }

    // MARK: - Inputs

    /// Use `timeline` (or none) from now on, re-showing the session time on
    /// show and re-plotting the lap.
    public func setTelemetry(_ timeline: TelemetryTimeline?) {
        telemetry = timeline
        samplingCursor = SamplingCursor()
        currentFrame = nil
        if plotLap == nil { plotLap = review.timeline.laps.first?.lap }
        if let displayedTime { show(sessionTime: displayedTime) }
        rebuildPanes()
    }

    /// Use the session's GPS `track` for the map.
    public func setTrack(_ track: [GPSTrackPoint]) {
        self.track = track
        rebuildPanes()
    }

    /// Load the session's telemetry from `analysis` — timed against the
    /// review's laps and sectors, with `channels` (the overlay's named readouts)
    /// sampled too — off the main actor. Only the load asked for last is kept:
    /// one superseded meanwhile, or cancelled, writes nothing.
    public func loadTelemetry(from analysis: AnalysisSession, channels: [String] = []) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let timeline = try? await TelemetryTimeline.load(from: analysis, timeline: review.timeline,
                                                               channels: channels),
              generation == loadGeneration else { return }
        setTelemetry(timeline)
    }

    // MARK: - The clock

    /// One displayed video frame at `playhead`. Playing, the frame at the mapped
    /// session time goes on show, and the cursor time and the end-of-window
    /// action come back for the shell to apply; paused, nothing happens — the
    /// cursor drives instead.
    @discardableResult
    public func tick(playhead: Double, isPlaying: Bool) -> VideoDataTick {
        guard isPlaying, playhead.isFinite else { return VideoDataTick(cursorTime: nil, action: .none) }
        let time = review.sync.cursorTime(forVideoTime: playhead)
        show(sessionTime: time)
        return VideoDataTick(cursorTime: review.sync.shouldDriveCursor(whilePlaying: true) ? time : nil,
                             action: review.playbackAction(atPlayhead: playhead))
    }

    /// The shared cursor moved to `cursorTime` (a scrub, a map click, a lap
    /// pick). Paused, its frame goes on show and the playhead to seek to comes
    /// back (`nil` without footage); playing, the move is the playhead's own
    /// echo and is ignored — so the two directions never feed back.
    @discardableResult
    public func follow(cursorTime: Double, isPlaying: Bool) -> Double? {
        guard !isPlaying, cursorTime.isFinite else { return nil }
        show(sessionTime: cursorTime)
        return review.sync.shouldSeek(whilePlaying: false) ? review.sync.videoTime(forCursorTime: cursorTime) : nil
    }

    /// Put session time `time` on show: its frame (published only when its
    /// readings changed), the lap it is in, and the footage there.
    public func show(sessionTime time: Double) {
        guard time.isFinite else { return }
        displayedTime = time
        if let telemetry {
            let frame = telemetry.frame(at: time, cursor: &samplingCursor)
            if !(currentFrame?.hasSameReadings(as: frame) ?? false) { currentFrame = frame }
        }
        if let lap = review.timeline.location(atSessionTime: time)?.lap { setPlotLap(lap) }
        refreshCoverage(sync: review.sync)
    }

    // MARK: - Footage at the cursor

    /// Whether the player shows "No footage here": there is footage, but none at
    /// the session time on show.
    public var showsNoFootage: Bool {
        review.hasVideo && displayedTime != nil && coverageAtCursor == .none
    }

    // MARK: - HUD

    /// The HUD's VoiceOver value — ``OverlayAccessibilitySummary`` of the frame
    /// on show, speed in `units`.
    public func accessibilitySummary(units: UnitSystem, locale: Locale = .current) -> String {
        OverlayAccessibilitySummary.text(for: currentFrame, units: units, locale: locale)
    }

    // MARK: - Internals

    private func refreshCoverage(sync: VideoSyncModel) {
        let coverage = displayedTime.map { sync.coverage(of: SessionTimeSpan(start: $0, end: $0)) } ?? .none
        if coverage != coverageAtCursor { coverageAtCursor = coverage }
    }

    /// Show `lap` on the plot and the map, rebuilding them only when it changed.
    func setPlotLap(_ lap: LapID) {
        guard lap != plotLap else { return }
        plotLap = lap
        rebuildPanes()
    }

    /// Re-sample the strip plot and re-cut the map for ``plotLap``.
    func rebuildPanes() {
        guard let lap = plotLap, let span = review.timeline.lapSpan(lap)?.span else {
            stripPlot = nil
            lapMap = nil
            return
        }
        stripPlot = telemetry.map { LapStripPlot(timeline: $0, lap: lap, span: span) }
        lapMap = track.isEmpty || span.end < span.start
            ? nil
            : TrackMapModel(track: track, laps: [span.start...span.end], lapNumbers: [lap.index + 1])
    }
}
