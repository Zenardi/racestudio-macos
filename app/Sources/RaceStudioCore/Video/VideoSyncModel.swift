import Foundation

/// The pure time-mapping between the analysis cursor's **session time** and an
/// imported video's **playhead** (parity gap 9.5, issue #140).
///
/// RaceStudio 3 plays an external session video tied to the linked cursor: scrub
/// the plot and the footage follows, or play the footage and the cursor tracks
/// it. This value type is that correspondence, and nothing else — no AVKit, no
/// playback state — so every mapping rule is unit-testable. The thin `@main`-shell
/// `AVPlayer` view binds to it: on a cursor move it seeks to
/// ``videoTime(forCursorTime:)``, and on a playhead tick it drives the cursor to
/// ``cursorTime(forVideoTime:)``.
///
/// The mapping is a single signed ``offset`` (seconds) the operator aligns once —
/// `videoTime = cursorTime + offset`, clamped to the footage's `0...duration` so a
/// seek can never run off either end. The inverse subtracts the same offset, so a
/// forward→back round-trip inside bounds recovers the original cursor time and an
/// offset edit re-projects with no accumulated drift.
public struct VideoSyncModel: Equatable, Sendable {

    /// The imported video's duration in seconds. Always finite and `>= 0`: a
    /// negative or non-finite input is sanitized to `0` (an empty video), so
    /// ``videoBounds`` is always a valid range.
    public let videoDuration: Double

    /// The signed sync offset in seconds: `videoTime = cursorTime + offset`. A
    /// positive offset means the footage leads the session clock. Immutable and
    /// always finite: it is only ever set through ``init(videoDuration:offset:)``
    /// / ``withOffset(_:)``, which sanitize a non-finite input to `0`, so the
    /// mapping can never be handed a `NaN` offset that would defeat the clamp.
    public let offset: Double

    /// The span the sync offset is adjustable over (± this many seconds each way):
    /// the range the UI slider exposes and ``aligned(playhead:toCursorTime:)``
    /// clamps into, so a computed alignment can never leave the control's bounds.
    public static let offsetRange: ClosedRange<Double> = -60...60

    /// Builds a mapping for a video of `videoDuration` seconds aligned by `offset`
    /// seconds. A non-finite or negative `videoDuration`, or a non-finite `offset`,
    /// is sanitized so the model can never trap or emit `NaN`.
    public init(videoDuration: Double, offset: Double = 0) {
        self.videoDuration = (videoDuration.isFinite && videoDuration > 0) ? videoDuration : 0
        self.offset = offset.isFinite ? offset : 0
    }

    /// Whether the video carries no playable footage (`duration <= 0`) — the map
    /// then pins every seek to `0`, and the shell shows no player.
    public var isEmpty: Bool { videoDuration <= 0 }

    /// The seekable playhead range, `0...videoDuration`. Always valid (the lower
    /// bound is `0` and the duration is a sanitized `>= 0`), so clamping into it
    /// never traps.
    public var videoBounds: ClosedRange<Double> { 0...videoDuration }

    /// The video playhead the cursor at `cursorTime` maps to: `cursorTime + offset`
    /// clamped to ``videoBounds`` (a non-finite cursor time pins to the start).
    /// This is the seek target the player follows as the linked cursor moves.
    public func videoTime(forCursorTime cursorTime: Double) -> Double {
        guard cursorTime.isFinite else { return videoBounds.lowerBound }
        return (cursorTime + offset).clamped(to: videoBounds)
    }

    /// The cursor time a video playhead at `videoTime` maps back to: the playhead
    /// is first clamped into ``videoBounds`` (a non-finite value pins to the
    /// start), then the offset is subtracted. The result is intentionally *not*
    /// clamped to any session bounds — the linked cursor owns that clamp — so the
    /// inverse stays exact and drift-free within the video's range.
    public func cursorTime(forVideoTime videoTime: Double) -> Double {
        let bounded = videoTime.isFinite ? videoTime.clamped(to: videoBounds) : videoBounds.lowerBound
        return bounded - offset
    }

    /// The same video re-aligned to `newOffset`. The mapping is a pure function of
    /// the current offset, so re-projecting through a fresh model carries no state
    /// from the old alignment — editing the offset and back yields an equal model.
    public func withOffset(_ newOffset: Double) -> VideoSyncModel {
        VideoSyncModel(videoDuration: videoDuration, offset: newOffset)
    }

    /// The same video re-aligned so the frame currently at video `playhead` maps to
    /// `cursorTime`: `offset = playhead − cursorTime`, clamped to ``offsetRange`` so
    /// a large gap can't push the offset outside the adjustable span (which would
    /// desync the UI slider). A non-finite input leaves the model unchanged.
    public func aligned(playhead: Double, toCursorTime cursorTime: Double) -> VideoSyncModel {
        guard playhead.isFinite, cursorTime.isFinite else { return self }
        return withOffset((playhead - cursorTime).clamped(to: Self.offsetRange))
    }

    /// Whether a cursor move should seek the video: only while the footage is
    /// paused and non-empty. When the video is playing it drives the cursor
    /// instead — so this and ``shouldDriveCursor(whilePlaying:)`` are never both
    /// `true`, which is what keeps the two directions from forming a feedback loop.
    public func shouldSeek(whilePlaying isPlaying: Bool) -> Bool {
        !isPlaying && !isEmpty
    }

    /// Whether a playhead tick should drive the shared cursor: only while the
    /// footage is playing and non-empty. Mutually exclusive with
    /// ``shouldSeek(whilePlaying:)`` (see there).
    public func shouldDriveCursor(whilePlaying isPlaying: Bool) -> Bool {
        isPlaying && !isEmpty
    }
}
