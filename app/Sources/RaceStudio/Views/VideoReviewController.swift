import SwiftUI
import AppKit
import AVFoundation
import os
import RaceStudioCore

/// The view-owned glue between one `AVPlayer`, the window's shared
/// ``LinkedCursor``, and the pure ``VideoDataViewModel`` / ``VideoReviewModel``
/// (issues 9.6, 9.12).
///
/// It holds no rules of its own. Every decision — where a cursor move seeks, how
/// a playhead tick maps back (and which telemetry frame the HUD shows), whether
/// a section is playable, and what to do when one ends — comes from
/// ``VideoDataViewModel`` / ``VideoReviewModel`` / ``VideoSyncModel`` in
/// `RaceStudioCore`, which is why this file (like the rest of the `@main` shell)
/// is excluded from the coverage metric: it only applies those decisions to AVKit.
///
/// The playhead is observed once per frame of the footage (its frame grid), so
/// the HUD, the plot cursor and the map dot move with every displayed frame.
///
/// A reference type so the periodic playhead observer always reads the *current*
/// alignment (an offset edit is never stale) and so cursor writes land on the
/// main actor.
@MainActor
final class VideoReviewController: ObservableObject {

    /// The player the panel renders. Item-less until footage is attached.
    let player = AVPlayer()

    /// The attached footage, or `nil` when none is (the panel then shows its
    /// designed empty state).
    @Published private(set) var attachment: VideoAttachment?

    /// Why the attached footage could not be opened, if it could not — shown
    /// rather than swallowed, so a moved file reads as "re-link me".
    @Published private(set) var loadFailure: String?

    /// Whether the player is currently playing (drives the play/pause control).
    @Published private(set) var isPlaying = false

    /// What became of the file-date guess on the last attach (issue 9.7) — the
    /// panel explains a date that does not fit the session.
    @Published private(set) var autoOffsetOutcome: AutoOffsetOutcome?

    /// Why the last two-point sync was refused, shown until the next attempt
    /// (issue 9.7). The previous sync stands meanwhile.
    @Published var twoPointError: TwoPointSyncError?

    /// Whether the open footage has an audio track to auto-sync from (issue
    /// 9.8) — `nil` while it is being checked.
    @Published var hasAudioTrack: Bool?

    /// The session's RPM channel, resolved once per session rather than on
    /// every render of the auto-sync button (issue 9.8).
    let rpmChannels: RPMChannelMemo

    /// The open footage, read again by an auto-sync run.
    var videoURL: URL?
    /// The auto-sync run the review owns, held so closing the window cancels
    /// it (the review cancels it on Cancel, apply and detach) and so only the
    /// current run's result is announced.
    var autoSyncRun: Task<Void, Never>?

    let review: VideoReviewModel
    private let data: VideoDataViewModel
    weak var cursor: LinkedCursor?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    /// Bumped by every open and detach, so an `open` still awaiting its asset
    /// when the footage is replaced or removed never writes into the new state.
    private var openGeneration = 0
    private let videos = VideoAttachmentStore(bookmarks: SecurityScopedBookmarkStore())
    private static let log = Logger(subsystem: "com.aim.racestudio", category: "VideoReview")

    init(data: VideoDataViewModel) {
        self.data = data
        self.review = data.review
        self.rpmChannels = RPMChannelMemo()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObserver?.invalidate()
        // A closed window stops decoding and matching rather than finishing for
        // no one.
        autoSyncRun?.cancel()
    }

    // MARK: - Attaching

    /// Bind the controller to the window's shared cursor and start observing the
    /// playhead. Called once, when the panel appears.
    func start(driving cursor: LinkedCursor) {
        self.cursor = cursor
        attachObservers()
    }

    /// Attach the video at `url` (a user pick), seed the mapping and frame grid
    /// from the asset, and propose a wall-clock alignment when both clocks are
    /// known and the footage would then overlap the session's
    /// `0...sessionDuration` (issue 9.7).
    ///
    /// Importing replaces the footage and forgets the old alignment with it — a
    /// different file must never inherit "Synced on lap 3". The one exception is
    /// re-linking a workspace video that failed to open, whose saved sync stands.
    func attach(_ url: URL, sessionStartEpoch: Double, sessionDuration: Double) async {
        let relinking = attachment != nil && loadFailure != nil
        if !relinking { review.detachVideo() }
        do {
            attachment = try videos.attach(url, offset: review.sync.offset)
        } catch {
            // A file we cannot bookmark can still be played this session; it just
            // will not survive into the saved workspace.
            Self.log.warning("Could not bookmark \(url.lastPathComponent, privacy: .public)")
            attachment = nil
        }
        loadFailure = nil
        autoOffsetOutcome = nil
        twoPointError = nil
        await open(url, sessionStartEpoch: sessionStartEpoch, sessionDuration: sessionDuration)
    }

    /// Re-open the footage a loaded `.rsproj` carries (issue 9.6's persistence),
    /// restoring the offset, rate and sync status it was saved with (9.7). A moved
    /// or deleted file leaves the panel in a stated failure rather than aborting
    /// the project load.
    func restore(_ attachment: VideoAttachment, sessionStartEpoch: Double) async {
        self.attachment = attachment
        review.restore(attachment)
        autoOffsetOutcome = nil
        twoPointError = nil
        do {
            let url = try videos.resolve(attachment)
            loadFailure = nil
            // The saved sync is authoritative — do not re-guess from wall clocks.
            await open(url, sessionStartEpoch: 0, sessionDuration: 0)
        } catch VideoAttachmentError.stale {
            clearPlayer()
            loadFailure = "“\(attachment.displayName)” has moved. Attach it again to re-link the video."
        } catch {
            clearPlayer()
            loadFailure = "“\(attachment.displayName)” could not be opened. It may have been deleted."
        }
    }

    /// Detach the footage, leaving the workspace without a video.
    func removeVideo() {
        stopAudioWork()
        openGeneration += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        attachment = nil
        loadFailure = nil
        autoOffsetOutcome = nil
        twoPointError = nil
        // The alignment belonged to that footage; the next video starts unsynced.
        review.detachVideo()
    }

    /// The attachment to persist: the current file re-stamped with the alignment
    /// in force — offset, rate and status — so a save captures a trim or a
    /// two-point sync made after attaching.
    var attachmentForSaving: VideoAttachment? {
        attachment.map(review.stamped)
    }

    // MARK: - Transport

    /// Play the section under review from its start (or resume free playback when
    /// nothing is selected).
    func playSelection() {
        if let target = review.seekTarget {
            seek(to: target) { [weak self] in self?.player.play() }
        } else {
            player.play()
        }
    }

    func pause() { player.pause() }

    /// *Play lap* (issue 9.12): play exactly the whole lap picked — or the lap at
    /// the cursor — from its first frame; the review's loop rule replays it.
    func playLap() {
        guard data.prepareLapPlayback() else { return }
        playSelection()
    }

    /// Stop playback at once — before a scrub of the plot or a click on the map —
    /// so the cursor move that follows seeks the footage (only a paused player
    /// follows the cursor) instead of being overridden by the next frame.
    func pauseForScrub() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    /// Move both the cursor and the playhead to the section under review — what a
    /// click in the lap/sector grid does.
    func goToSelection() {
        if let cursorTarget = review.cursorTarget { cursor?.moveTime(cursorTarget) }
        if let target = review.seekTarget { seek(to: target) }
    }

    /// Cursor → video while paused: show the cursor's telemetry and follow it
    /// with the footage. The pure 9.5 gate stands this down while the footage is
    /// driving the cursor instead.
    func seekFromCursor(to cursorTime: Double) {
        guard let playhead = data.follow(cursorTime: cursorTime, isPlaying: isPlaying) else { return }
        seek(to: playhead)
    }

    /// Re-align to `offset` (the fine-trim slider) and re-seek so the visible
    /// frame follows immediately.
    func setOffset(_ offset: Double) {
        review.setOffset(offset)
        twoPointError = nil
        seekFromCursor(to: cursor?.timePosition ?? 0)
    }

    /// Anchor the section under review to the frame on screen — the track-aware
    /// sync. Returns `false` when nothing is selected to anchor against.
    @discardableResult
    func anchorToCurrentFrame() -> Bool {
        twoPointError = nil
        return review.anchorSelection(toPlayhead: player.currentTime().seconds)
    }

    /// Apply one fine-trim nudge (`,` / `.`, with `⇧` or `⌥`) and re-seek so the
    /// visible frame follows (issue 9.7).
    func nudge(_ nudge: OffsetNudge) {
        review.nudge(nudge)
        twoPointError = nil
        seekFromCursor(to: cursor?.timePosition ?? 0)
    }

    /// Pin two-point anchor `slot` to the frame on screen, against the start of
    /// the section under review (issue 9.7).
    func setAnchor(_ slot: AnchorSlot) {
        review.setAnchor(slot, playhead: player.currentTime().seconds)
        twoPointError = nil
    }

    /// Solve offset and rate from anchors A and B (issue 9.7). A refusal is kept
    /// for the panel to explain and the previous sync stands; a success re-seeks
    /// so the visible frame follows the new mapping.
    func applyTwoPointSync() {
        switch review.applyTwoPointSync() {
        case .success:
            twoPointError = nil
            seekFromCursor(to: cursor?.timePosition ?? 0)
        case .failure(let error):
            twoPointError = error
            announce(error.message())
        }
    }

    // MARK: - Internals

    private func open(_ url: URL, sessionStartEpoch: Double, sessionDuration: Double) async {
        openGeneration += 1
        let generation = openGeneration
        stopAudioWork()
        videoURL = url
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        // Whether there is engine sound to auto-sync from (issue 9.8).
        Task { [weak self] in
            let hasAudio = await AVAssetAudioPCMSource.hasAudioTrack(at: url)
            guard let self, generation == self.openGeneration else { return }
            self.hasAudioTrack = hasAudio
        }
        // Each await below may outlive this footage (re-attached or removed in
        // the meantime); a superseded open stops rather than writing stale state.
        do {
            let duration = try await asset.load(.duration).seconds
            guard generation == openGeneration else { return }
            review.setVideoDuration(duration)
        } catch {
            Self.log.warning("Could not read video duration: \(error.localizedDescription, privacy: .public)")
        }
        let frameRate = await nominalFrameRate(of: asset)
        guard generation == openGeneration else { return }
        review.setFrameRate(frameRate)
        // Observe the playhead once per frame of this footage.
        attachObservers()
        // A camera that stamps its start time gives a usable first alignment for
        // free; without one — or when the date cannot be right for this session —
        // the operator anchors to a lap by hand.
        guard sessionStartEpoch > 0,
              let created = try? await asset.load(.creationDate)?.load(.dateValue),
              generation == openGeneration else { return }
        autoOffsetOutcome = review.applyAutoOffset(sessionStartEpoch: sessionStartEpoch,
                                                   videoStartEpoch: created.timeIntervalSince1970,
                                                   sessionDuration: sessionDuration)
    }

    /// The first video track's nominal frame rate (issue 9.7), so a frame step is
    /// exactly one of this footage's frames — or `0`, which the model reads as
    /// "unknown" and replaces with its 30 fps fallback, so a clip without a
    /// readable track never keeps the previous clip's grid.
    private func nominalFrameRate(of asset: AVURLAsset) async -> Double {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
            return Double(try await track.load(.nominalFrameRate))
        } catch {
            Self.log.warning("Could not read the frame rate: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Drop the player's footage after a failed restore, so no stale frame (or
    /// stale length) can be anchored against while the panel asks to re-link.
    private func clearPlayer() {
        openGeneration += 1
        stopAudioWork()
        player.replaceCurrentItem(with: nil)
        review.setVideoDuration(0)
    }

    /// Speak `message` to VoiceOver users, who cannot see the panel's notice.
    /// Posted on the window (announcements on the application object are
    /// sometimes dropped), falling back to the app.
    func announce(_ message: String) {
        let element: Any = NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func seek(to playhead: Double, then completion: (() -> Void)? = nil) {
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion?() }
        }
    }

    private func attachObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        // One tick per frame of the footage (29.97 fps → 1001/30000 s).
        let grid = review.frameGrid
        let interval = CMTime(value: CMTimeValue(grid.denominator), timescale: CMTimeScale(grid.numerator))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Delivered on .main; hop to the main actor so the cursor write is safe.
            Task { @MainActor [weak self] in self?.tick(at: time) }
        }
        statusObserver?.invalidate()
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.isPlaying = player.timeControlStatus == .playing }
        }
    }

    /// One playhead tick: show its telemetry frame and drive the shared cursor
    /// (9.5, 9.12), then apply the reviewed section's end rule (9.6).
    private func tick(at time: CMTime) {
        let result = data.tick(playhead: time.seconds, isPlaying: isPlaying)
        if let cursorTime = result.cursorTime { cursor?.moveTime(cursorTime) }
        switch result.action {
        case .none:
            break
        case .seek(let target):
            seek(to: target)
        case .stop:
            player.pause()
        }
    }
}
