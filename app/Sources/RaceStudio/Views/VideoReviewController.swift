import SwiftUI
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

    private let review: VideoReviewModel
    private weak var cursor: LinkedCursor?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
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
    func attach(_ url: URL, sessionStartEpoch: Double, sessionDuration: Double) async {
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
            loadFailure = "“\(attachment.displayName)” has moved. Attach it again to re-link the video."
        } catch {
            loadFailure = "“\(attachment.displayName)” could not be opened. It may have been deleted."
        }
    }

    /// Detach the footage, leaving the workspace without a video.
    func removeVideo() {
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
        seekFromCursor(to: cursor?.timePosition ?? 0)
    }

    /// Anchor the section under review to the frame on screen — the track-aware
    /// sync. Returns `false` when nothing is selected to anchor against.
    @discardableResult
    func anchorToCurrentFrame() -> Bool {
        review.anchorSelection(toPlayhead: player.currentTime().seconds)
    }

    /// Apply one fine-trim nudge (`,` / `.`, with `⇧` or `⌥`) and re-seek so the
    /// visible frame follows (issue 9.7).
    func nudge(_ nudge: OffsetNudge) {
        review.nudge(nudge)
        seekFromCursor(to: cursor?.timePosition ?? 0)
    }

    /// Pin two-point anchor `slot` to the frame on screen, against the start of
    /// the section under review (issue 9.7).
    func setAnchor(_ slot: AnchorSlot) {
        review.setAnchor(slot, playhead: player.currentTime().seconds)
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
        }
    }

    // MARK: - Internals

    private func open(_ url: URL, sessionStartEpoch: Double, sessionDuration: Double) async {
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        do {
            review.setVideoDuration(try await asset.load(.duration).seconds)
        } catch {
            Self.log.warning("Could not read video duration: \(error.localizedDescription, privacy: .public)")
        }
        await loadFrameRate(of: asset)
        // A camera that stamps its start time gives a usable first alignment for
        // free; without one — or when the date cannot be right for this session —
        // the operator anchors to a lap by hand.
        if sessionStartEpoch > 0,
           let created = try? await asset.load(.creationDate)?.load(.dateValue) {
            autoOffsetOutcome = review.applyAutoOffset(sessionStartEpoch: sessionStartEpoch,
                                                       videoStartEpoch: created.timeIntervalSince1970,
                                                       sessionDuration: sessionDuration)
        }
    }

    /// Seed the frame grid from the first video track's nominal frame rate
    /// (issue 9.7), so a frame step is exactly one of this footage's frames.
    /// Without a readable track the model keeps its 30 fps fallback.
    private func loadFrameRate(of asset: AVURLAsset) async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            review.setFrameRate(Double(try await track.load(.nominalFrameRate)))
        } catch {
            Self.log.warning("Could not read the frame rate: \(error.localizedDescription, privacy: .public)")
        }
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
