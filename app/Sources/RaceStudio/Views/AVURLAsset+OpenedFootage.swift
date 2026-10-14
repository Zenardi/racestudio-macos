import AVFoundation
import os
import RaceStudioCore

/// Reads what an opened video file says about itself (issue 229) — its
/// length, its frame rate and, for newly attached footage, its file date — so
/// ``VideoReviewController`` can hand it to the core in one step. Only reads:
/// what to do with the values is ``VideoDataViewModel/footageOpened(_:cursorTime:isPlaying:)``'s.
extension AVURLAsset {

    private static let log = Logger(subsystem: "com.aim.racestudio", category: "VideoReview")

    /// The footage's length, frame rate and — when `sessionStartEpoch` is
    /// known — its file date against the session's `0...sessionDuration`.
    /// A restored workspace passes `0`: its saved sync is authoritative.
    func openedFootage(sessionStartEpoch: Double, sessionDuration: Double) async -> OpenedFootage {
        let duration = await length()
        let frameRate = await nominalFrameRate()
        let fileDate = sessionStartEpoch > 0
            ? await fileDate(sessionStartEpoch: sessionStartEpoch, sessionDuration: sessionDuration)
            : nil
        return OpenedFootage(duration: duration, nominalFrameRate: frameRate, fileDate: fileDate)
    }

    /// The footage's length in seconds, or `nil` when it can't be read.
    private func length() async -> Double? {
        do {
            return try await load(.duration).seconds
        } catch {
            Self.log.warning("Could not read video duration: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The first video track's nominal frame rate (issue 9.7), so a frame step is
    /// exactly one of this footage's frames — or `0`, which the model reads as
    /// "unknown" and replaces with its 30 fps fallback, so a clip without a
    /// readable track never keeps the previous clip's grid.
    private func nominalFrameRate() async -> Double {
        do {
            guard let track = try await loadTracks(withMediaType: .video).first else { return 0 }
            return Double(try await track.load(.nominalFrameRate))
        } catch {
            Self.log.warning("Could not read the frame rate: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// A camera that stamps its start time gives a usable first alignment for
    /// free (issue 9.7); without one the operator anchors to a lap by hand.
    private func fileDate(sessionStartEpoch: Double, sessionDuration: Double) async -> OpenedFootage.FileDate? {
        guard let created = try? await load(.creationDate)?.load(.dateValue) else { return nil }
        return OpenedFootage.FileDate(sessionStartEpoch: sessionStartEpoch,
                                      videoStartEpoch: created.timeIntervalSince1970,
                                      sessionDuration: sessionDuration)
    }
}
