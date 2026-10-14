import Foundation

/// What an opened video file says about itself (issue 229): its length and
/// frame rate, and — for newly attached footage only — the file date a first
/// alignment may be guessed from.
public struct OpenedFootage: Equatable, Sendable {

    /// The two wall clocks a first alignment is guessed from, and the session
    /// length the guess must overlap (issue 9.7).
    public struct FileDate: Equatable, Sendable {
        public let sessionStartEpoch: Double
        public let videoStartEpoch: Double
        public let sessionDuration: Double

        public init(sessionStartEpoch: Double, videoStartEpoch: Double, sessionDuration: Double) {
            self.sessionStartEpoch = sessionStartEpoch
            self.videoStartEpoch = videoStartEpoch
            self.sessionDuration = sessionDuration
        }
    }

    /// The footage's length in seconds, or `nil` when it could not be read —
    /// the footage then stays unplayable.
    public let duration: Double?
    /// The first video track's nominal frame rate, or `0` when unknown.
    public let nominalFrameRate: Double
    /// The file date to guess a first alignment from, or `nil` — always `nil`
    /// for footage a workspace restores, whose saved sync is authoritative.
    public let fileDate: FileDate?

    public init(duration: Double?, nominalFrameRate: Double, fileDate: FileDate? = nil) {
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.fileDate = fileDate
    }
}

/// What opening footage did (issue 229).
public struct FootageOpening: Equatable, Sendable {
    /// What became of the file-date guess, or `nil` when none was offered.
    public let autoOffset: AutoOffsetOutcome?
    /// Where the paused player must stand — the cursor's frame under the sync
    /// in force — or `nil` to leave it where it is.
    public let playhead: Double?
}

public extension VideoDataViewModel {

    /// The footage has opened (issue 229): seed its length and frame grid,
    /// apply the file-date guess when one is offered, and put the cursor's
    /// session time on show.
    ///
    /// The panel may ask the player to follow the cursor before the footage has
    /// loaded — a reopened session restores its layout first — and that cannot
    /// seek. So once the footage is in, the answer says where a paused player
    /// must stand, and a reopened session shows the frame that matches its data
    /// instead of the footage's first frame, which reads as a lost sync.
    ///
    /// - Parameters:
    ///   - cursorTime: the window's cursor, or `nil` before the panel has bound
    ///     one (it follows the cursor itself when it appears).
    ///   - isPlaying: whether the footage is playing; playing footage drives
    ///     the cursor, so it is never moved.
    func footageOpened(_ footage: OpenedFootage, cursorTime: Double?, isPlaying: Bool) -> FootageOpening {
        if let duration = footage.duration { review.setVideoDuration(duration) }
        review.setFrameRate(footage.nominalFrameRate)
        let autoOffset = footage.fileDate.map {
            review.applyAutoOffset(sessionStartEpoch: $0.sessionStartEpoch, videoStartEpoch: $0.videoStartEpoch,
                                   sessionDuration: $0.sessionDuration)
        }
        let playhead = cursorTime.flatMap { follow(cursorTime: $0, isPlaying: isPlaying) }
        return FootageOpening(autoOffset: autoOffset, playhead: playhead)
    }
}
