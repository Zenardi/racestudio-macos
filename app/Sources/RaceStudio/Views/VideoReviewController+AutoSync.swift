import SwiftUI
import AVFoundation
import RaceStudioCore

/// Auto-sync from engine sound (issue 9.8): the run the review owns, started,
/// cancelled, applied and dismissed from the sync bar. Split from
/// `VideoReviewController.swift` to keep each file readable; the rules are
/// ``VideoReviewModel``'s.
extension VideoReviewController {

    /// Start matching the footage's engine sound against `analysis`'s RPM. The
    /// run's progress and proposal land in the review's `autoSyncState`;
    /// nothing is applied until ``applyAutoSync()``. VoiceOver hears the result
    /// when it arrives.
    func startAutoSync(analysis: AnalysisSession?) {
        guard let url = videoURL, let analysis,
              let range = analysis.audioSyncSearchRange(videoDuration: review.sync.videoDuration),
              let coordinator = analysis.audioSyncCoordinator(source: AVAssetAudioPCMSource(url: url)) else { return }
        let run = review.startAutoSync(coordinator, searchRange: range)
        autoSyncRun = run
        Task { [weak self] in
            await run.value
            guard let self, self.autoSyncRun == run, let message = self.review.autoSyncState.announcement() else {
                return
            }
            self.announce(message)
        }
    }

    /// Cancel: stop the run at once; the sync in force is untouched.
    func cancelAutoSync() {
        autoSyncRun = nil
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
    func stopAudioWork() {
        cancelAutoSync()
        videoURL = nil
        hasAudioTrack = nil
    }
}
