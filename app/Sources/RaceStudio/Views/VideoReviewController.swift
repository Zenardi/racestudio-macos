import SwiftUI
import AppKit
import AVFoundation
import os
import RaceStudioCore

/// The view-owned glue between one `AVPlayer`, the window's shared
/// ``LinkedCursor``, and the pure ``VideoReviewModel`` (issue 9.6).
///
/// It holds no rules of its own. Every decision — where a cursor move seeks, how
/// a playhead tick maps back, whether a section is playable, and what to do when
/// one ends — comes from ``VideoReviewModel`` / ``VideoSyncModel`` in
/// `RaceStudioCore`, which is why this file (like the rest of the `@main` shell)
/// is excluded from the coverage metric: it only applies those decisions to AVKit.
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
    @Published private(set) var twoPointError: TwoPointSyncError?

    /// Whether the open footage has an audio track to auto-sync from (issue
    /// 9.8) — `nil` while it is being checked.
    @Published private(set) var hasAudioTrack: Bool?

    /// The open footage, read again by an auto-sync run.
    private var videoURL: URL?
    /// The auto-sync run in flight, cancelled by Cancel or by new footage.
    private var autoSyncTask: Task<Void, Never>?

    private let review: VideoReviewModel
    private weak var cursor: LinkedCursor?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    /// Bumped by every open and detach, so an `open` still awaiting its asset
    /// when the footage is replaced or removed never writes into the new state.
    private var openGeneration = 0
    private let videos = VideoAttachmentStore(bookmarks: SecurityScopedBookmarkStore())
    private static let log = Logger(subsystem: "com.aim.racestudio", category: "VideoReview")

    init(review: VideoReviewModel) {
        self.review = review
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObserver?.invalidate()
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

    /// Move both the cursor and the playhead to the section under review — what a
    /// click in the lap/sector grid does.
    func goToSelection() {
        if let cursorTarget = review.cursorTarget { cursor?.moveTime(cursorTarget) }
        if let target = review.seekTarget { seek(to: target) }
    }

    /// Cursor → video while paused: follow the shared cursor. The pure 9.5 gate
    /// stands this down while the footage is driving the cursor instead.
    func seekFromCursor(to cursorTime: Double) {
        guard review.sync.shouldSeek(whilePlaying: isPlaying) else { return }
        seek(to: review.sync.videoTime(forCursorTime: cursorTime))
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

    // MARK: - Auto-sync from engine sound (issue 9.8)

    /// Start matching the footage's engine sound against `analysis`'s RPM. The
    /// run's progress and proposal land in the review's `autoSyncState`;
    /// nothing is applied until ``applyAutoSync()``.
    func startAutoSync(analysis: AnalysisSession?) {
        guard let url = videoURL, let analysis,
              let range = analysis.audioSyncSearchRange(videoDuration: review.sync.videoDuration),
              let coordinator = analysis.audioSyncCoordinator(source: AVAssetAudioPCMSource(url: url)) else { return }
        autoSyncTask?.cancel()
        autoSyncTask = Task { [review] in await review.runAutoSync(coordinator, searchRange: range) }
    }

    /// Cancel: stop the run at once; the sync in force is untouched.
    func cancelAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        review.cancelAutoSync()
    }

    /// Apply the confident proposal the operator confirmed, and re-seek so the
    /// visible frame follows the new alignment.
    func applyAutoSync() {
        guard let proposal = review.autoSyncState.proposal, review.applyAudioSync(proposal) else { return }
        twoPointError = nil
        seekFromCursor(to: cursor?.timePosition ?? 0)
        announce(review.status.label())
    }

    /// Close the result without applying it.
    func dismissAutoSync() {
        review.dismissAutoSync()
    }

    /// Stop any auto-sync work tied to the footage being replaced or removed.
    private func stopAudioWork() {
        cancelAutoSync()
        videoURL = nil
        hasAudioTrack = nil
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
    private func announce(_ message: String) {
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
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Delivered on .main; hop to the main actor so the cursor write is safe.
            Task { @MainActor [weak self] in self?.tick(at: time) }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.isPlaying = player.timeControlStatus == .playing }
        }
    }

    /// One playhead tick: drive the shared cursor (9.5), then apply the reviewed
    /// section's end rule (9.6).
    private func tick(at time: CMTime) {
        let playhead = time.seconds
        if review.sync.shouldDriveCursor(whilePlaying: isPlaying), let cursor {
            cursor.moveTime(review.sync.cursorTime(forVideoTime: playhead))
        }
        guard isPlaying else { return }
        switch review.playbackAction(atPlayhead: playhead) {
        case .none:
            break
        case .seek(let target):
            seek(to: target)
        case .stop:
            player.pause()
        }
    }
}
