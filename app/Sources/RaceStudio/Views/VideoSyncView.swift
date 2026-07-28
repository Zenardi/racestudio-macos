import SwiftUI
import AVKit
import os
import RaceStudioCore

/// The external session-video panel (parity gap 9.5, issue #140): an `AVPlayer`
/// tied to the window's shared 8.3 ``LinkedCursor`` through a ``VideoSyncModel``.
///
/// Thin, as the shell is (coverage-excluded): every time rule lives in the pure
/// ``VideoSyncModel`` in `RaceStudioCore` — the clamped offset math *and* the
/// direction gate. ``VideoSyncController`` owns the `AVPlayer` and applies those
/// decisions, so the two directions never fight —
///
/// * **paused / scrubbing:** a cursor move seeks the player to
///   ``VideoSyncModel/videoTime(forCursorTime:)`` (clamped to the footage).
/// * **playing:** the periodic playhead observer drives the cursor to
///   ``VideoSyncModel/cursorTime(forVideoTime:)`` on the shared time axis.
struct VideoSyncView: View {
    @ObservedObject var cursor: LinkedCursor
    @StateObject private var controller: VideoSyncController

    init(cursor: LinkedCursor, videoURL: URL) {
        self.cursor = cursor
        _controller = StateObject(wrappedValue: VideoSyncController(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 8) {
            VideoPlayer(player: controller.player)
                .frame(minWidth: 240, minHeight: 135)
                .accessibilityLabel(L10n.string(.featureVideoSync))
            offsetControls
        }
        .padding(8)
        .task { await controller.start(driving: cursor) }
        .onChange(of: cursor.timePosition) { controller.seekFromCursor(to: $0) }
    }

    private var offsetControls: some View {
        HStack(spacing: 10) {
            Text(L10n.string(.controlVideoOffset))
            Slider(value: offsetBinding, in: VideoSyncModel.offsetRange) {
                Text(L10n.string(.controlVideoOffset))
            }
            .disabled(controller.sync.isEmpty)
            Text(String(format: "%+.2f s", controller.sync.offset))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Button(L10n.string(.controlAlignVideoToCursor)) { controller.alignOffsetToCursor() }
                .disabled(controller.sync.isEmpty)
                .help("Set the offset so the current frame lines up with the cursor")
        }
        .font(.callout)
    }

    /// Edits the offset live through the controller (which re-projects and
    /// re-seeks) so a drag has no accumulated drift.
    private var offsetBinding: Binding<Double> {
        Binding(get: { controller.sync.offset }, set: { controller.setOffset($0) })
    }
}

/// The view-owned glue between one `AVPlayer` and the shared ``LinkedCursor``
/// (issue #140). Kept a reference type so the periodic playhead observer reads the
/// *current* ``sync`` (an offset edit is never stale) and so cursor writes land on
/// the main actor. Lives in the shell — coverage-excluded, every decision (the
/// clamped offset, the direction gate) delegated to the pure ``VideoSyncModel``.
@MainActor
final class VideoSyncController: ObservableObject {
    let player: AVPlayer

    /// The live session↔video mapping the view's slider edits and both directions
    /// read. Re-seeded with the real duration once the asset loads.
    @Published private(set) var sync = VideoSyncModel(videoDuration: 0)

    private weak var cursor: LinkedCursor?
    private var timeObserver: Any?
    private static let log = Logger(subsystem: "com.aim.racestudio", category: "VideoSync")

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    /// Loads the asset duration (async on macOS 13), seeds the mapping, and starts
    /// driving `cursor` from the playhead during playback. A load failure is logged
    /// (not swallowed) and leaves the panel in its empty, controls-disabled state.
    func start(driving cursor: LinkedCursor) async {
        self.cursor = cursor
        if let asset = player.currentItem?.asset {
            do {
                let duration = try await asset.load(.duration)
                sync = VideoSyncModel(videoDuration: duration.seconds, offset: sync.offset)
            } catch {
                Self.log.warning("Could not read video duration: \(error.localizedDescription, privacy: .public)")
            }
        }
        attachObserver()
    }

    /// Cursor → video, while paused / scrubbing: seek to the mapped playhead. The
    /// pure gate stands this down while the video is driving the cursor.
    func seekFromCursor(to cursorTime: Double) {
        guard sync.shouldSeek(whilePlaying: isPlaying) else { return }
        let target = sync.videoTime(forCursorTime: cursorTime)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Re-align to a new offset (from the slider) and re-seek so the visible frame
    /// follows immediately. The mapping re-projects purely from `newOffset`.
    func setOffset(_ newOffset: Double) {
        sync = sync.withOffset(newOffset)
        seekFromCursor(to: cursor?.timePosition ?? 0)
    }

    /// Align the offset so the frame on screen now maps to the current cursor time
    /// (clamped to the adjustable span inside ``VideoSyncModel/aligned(playhead:toCursorTime:)``).
    func alignOffsetToCursor() {
        guard let cursor else { return }
        sync = sync.aligned(playhead: player.currentTime().seconds, toCursorTime: cursor.timePosition)
    }

    private var isPlaying: Bool { player.timeControlStatus == .playing }

    private func attachObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Delivered on .main; hop to the main actor so the cursor write is safe.
            Task { @MainActor [weak self] in self?.driveCursor(from: time) }
        }
    }

    /// Video → cursor, while playing: move the shared cursor to the mapped time.
    private func driveCursor(from time: CMTime) {
        guard sync.shouldDriveCursor(whilePlaying: isPlaying), let cursor else { return }
        cursor.moveTime(sync.cursorTime(forVideoTime: time.seconds))
    }
}
